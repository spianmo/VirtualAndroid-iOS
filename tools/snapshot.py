"""Suspend / restore a ranchu VM through QMP (docs/SNAPSHOT.md).

usage: python3 -I tools/snapshot.py <command> --run RUN_DIR [options]

  launch    (run-macos.sh) write launch.json for the QEMU about to start:
            launch --run R --qemu BIN --gfx LIB --images F... -- ARGV...
  status    print the manifest and whether it is usable for --launch
  check     exit 0 if RUN_DIR/snapshot holds a clean snapshot matching the
            launch description (--launch, default RUN_DIR/snapshot/launch.json)
  suspend   stop the VM and save it (cpr-reboot: RAM stays in ram.img, only
            device + GPU state go to state.bin); writes manifest clean=true.
            --quit then quits QEMU; otherwise it stays paused (see resume).
  resume    continue a VM paused by suspend (marks the snapshot dirty first)
  restore   feed RUN_DIR/snapshot/state.bin to a QEMU started with the same
            argv plus "-incoming defer"; marks the snapshot dirty BEFORE the
            guest runs. --adb-port P waits for sys.boot_completed=1 over adb,
            --frame-dir D waits for a new guest frame in D/latest.png.
  discard   delete the snapshot (cold boot next time)

Layout of RUN_DIR/snapshot: ram.img (guest RAM, memory-backend-file),
as.img (goldfish_address_space blocks), gfx/ (renderer bulk state),
state.bin (migration stream), manifest.json, launch.json (written by
run-macos.sh: qemu, gfx_lib, image files and the cold-boot argv),
last-frame.png (copy of the last dumped frame, if any).

Manifest "clean" rule: true only between a completed suspend and the next
moment the guest may run (restore/resume/cold boot set it to false first).
Any mismatch of engine / renderer / image / argv hashes makes it unusable.
"""
import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import time

MANIFEST_VERSION = 1
# argv elements that do not change the machine (dropped before hashing).
ARGV_IGNORE_WITH_VALUE = {"-incoming", "-trace", "-D", "-qmp"}


def now():
    return time.monotonic()


class Qmp:
    def __init__(self, path, timeout=30.0):
        deadline = now() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError:
                self.sock.close()
                if now() > deadline:
                    raise
                time.sleep(0.02)
        self.buf = b""
        self.events = []
        self._recv()                              # greeting
        self.cmd("qmp_capabilities")

    def _recv(self):
        while b"\n" not in self.buf:
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError("QMP connection closed")
            self.buf += data
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def cmd(self, name, **args):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        self.sock.sendall(json.dumps(msg).encode() + b"\n")
        while True:
            r = self._recv()
            if "event" in r:
                self.events.append(r)
                continue
            if "error" in r:
                raise RuntimeError("%s: %s" % (name, r["error"].get("desc")))
            return r.get("return")


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                return h.hexdigest()
            h.update(b)


def file_id(path):
    """Cheap identity for big read-only files: path, size, mtime."""
    st = os.stat(path)
    return "%s:%d:%d" % (os.path.basename(path), st.st_size, int(st.st_mtime))


def argv_hash(argv):
    out, skip = [], False
    for a in argv:
        if skip:
            skip = False
            continue
        if a in ARGV_IGNORE_WITH_VALUE:
            skip = True
            continue
        out.append(a)
    return hashlib.sha256("\0".join(out).encode()).hexdigest()


def describe(launch):
    """Hashes that must match between suspend and restore."""
    gfx = launch.get("gfx_lib") or ""
    return {
        # size + mtime: cheap enough to check on every launch
        "engine": file_id(launch["qemu"]),
        "gfx": file_id(gfx) if gfx and os.path.exists(gfx) else "none",
        "image": hashlib.sha256("|".join(
            file_id(p) for p in launch.get("image_files", [])).encode()
        ).hexdigest(),
        "argv_hash": argv_hash(launch["argv"]),
    }


def snap_dir(run):
    return os.path.join(run, "snapshot")


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def set_clean(run, clean):
    path = os.path.join(snap_dir(run), "manifest.json")
    m = read_json(path)
    if m is None:
        return
    m["clean"] = clean
    write_json(path, m)


def validity(run, launch_path=None):
    """(ok, reason, manifest)"""
    snap = snap_dir(run)
    m = read_json(os.path.join(snap, "manifest.json"))
    if m is None:
        return False, "no manifest", None
    if m.get("version") != MANIFEST_VERSION:
        return False, "manifest version", m
    if not m.get("clean"):
        return False, "not clean (killed while running?)", m
    for f in ("state.bin", "ram.img"):
        if not os.path.exists(os.path.join(snap, f)):
            return False, "missing " + f, m
    launch = read_json(launch_path or os.path.join(snap, "launch.json"))
    if launch is None:
        return False, "no launch description", m
    cur = describe(launch)
    for k, v in cur.items():
        if m.get(k) != v:
            return False, "%s changed" % k, m
    return True, "ok", m


def cmd_status(a):
    ok, why, m = validity(a.run, a.launch)
    print(json.dumps({"usable": ok, "reason": why, "manifest": m}, indent=1))
    return 0


def cmd_check(a):
    ok, why, _ = validity(a.run, a.launch)
    if not ok:
        print("snapshot not usable: " + why, file=sys.stderr)
    return 0 if ok else 1


def wait_migration(q, what, timeout):
    deadline = now() + timeout
    while True:
        st = q.cmd("query-migrate")
        status = st.get("status") if st else None
        if status == "completed":
            return st
        if status in ("failed", "cancelled"):
            raise RuntimeError("%s %s: %s" % (what, status,
                                              st.get("error-desc", "")))
        if now() > deadline:
            raise RuntimeError("%s timed out (status %s)" % (what, status))
        time.sleep(0.005)


def cmd_suspend(a):
    snap = snap_dir(a.run)
    launch = read_json(a.launch or os.path.join(snap, "launch.json"))
    if launch is None:
        print("no launch.json; was the VM started with run-macos.sh "
              "--snapshot?", file=sys.stderr)
        return 2
    q = Qmp(os.path.join(a.run, "qmp.sock"))
    t0 = now()
    q.cmd("stop")
    t_stop = now()
    q.cmd("migrate-set-parameters", mode="cpr-reboot")
    q.cmd("migrate-set-capabilities", capabilities=[
        {"capability": "x-ignore-shared", "state": True}])
    tmp = os.path.join(snap, "state.tmp")
    if os.path.exists(tmp):
        os.unlink(tmp)
    q.cmd("migrate", uri="file:" + tmp)
    st = wait_migration(q, "suspend", a.timeout)
    t_saved = now()
    os.replace(tmp, os.path.join(snap, "state.bin"))
    if a.frame_dir:
        frame = os.path.join(a.frame_dir, "latest.png")
        if os.path.exists(frame):
            shutil.copyfile(frame, os.path.join(snap, "last-frame.png"))
    # Identities as of launch: files replaced while running don't count.
    m = dict(launch.get("ids") or describe(launch))
    m.update({
        "version": MANIFEST_VERSION,
        "clean": True,
        "saved_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "state_bytes": os.path.getsize(os.path.join(snap, "state.bin")),
        "suspend_ms": round((t_saved - t0) * 1000),
        "ram_transferred": st.get("ram", {}).get("transferred"),
    })
    write_json(os.path.join(snap, "manifest.json"), m)
    t_done = now()
    print("suspended: stop %.0f ms, migrate %.0f ms, total %.0f ms, "
          "state.bin %.1f MB, ram copied %.1f MB" % (
              (t_stop - t0) * 1000, (t_saved - t_stop) * 1000,
              (t_done - t0) * 1000, m["state_bytes"] / 1e6,
              (m["ram_transferred"] or 0) / 1e6))
    if a.quit:
        try:
            q.cmd("quit")
        except (ConnectionError, OSError):
            pass
    return 0


def cmd_resume(a):
    set_clean(a.run, False)
    q = Qmp(os.path.join(a.run, "qmp.sock"))
    q.cmd("cont")
    print("resumed")
    return 0


def adb(args, timeout=3.0):
    """Runs adb with output in a temp file: an adb that spawns the adb
    server would keep pipes open (and subprocess waiting) forever."""
    import tempfile
    with tempfile.TemporaryFile() as out:
        try:
            p = subprocess.Popen(["adb"] + args, stdin=subprocess.DEVNULL,
                                 stdout=out, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        except OSError:
            return ""
        try:
            p.wait(timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
            return ""
        out.seek(0)
        return out.read().decode(errors="replace")


def adb_boot_completed(port):
    serial = "127.0.0.1:%d" % port
    return adb(["-s", serial, "shell", "getprop sys.boot_completed"],
               1.5).strip() == "1"


def cmd_restore(a):
    snap = snap_dir(a.run)
    t0 = a.t0 if a.t0 else time.time()
    mono0 = now() - (time.time() - t0)
    q = Qmp(os.path.join(a.run, "qmp.sock"))
    t_qmp = now()
    # The guest is about to run: from here on ram.img/disks diverge.
    set_clean(a.run, False)
    q.cmd("migrate-set-parameters", mode="cpr-reboot")
    q.cmd("migrate-set-capabilities", capabilities=[
        {"capability": "x-ignore-shared", "state": True}])
    q.cmd("migrate-incoming", uri="file:" + os.path.join(snap, "state.bin"))
    deadline = now() + a.timeout
    wait_migration(q, "restore", a.timeout)
    t_loaded = now()
    # The source was stopped before saving, so QEMU keeps the VM paused.
    if q.cmd("query-status")["status"] != "running":
        q.cmd("cont")
    t_run = now()
    print("restored: qemu up %.0f ms, load %.0f ms, running at "
          "%.0f ms after launch" % ((t_qmp - mono0) * 1000,
                                    (t_loaded - t_qmp) * 1000,
                                    (t_run - mono0) * 1000), flush=True)
    if a.frame_dir:
        frame = os.path.join(a.frame_dir, "latest.png")
        while now() < deadline:
            if os.path.exists(frame) and os.path.getmtime(frame) > t0:
                print("first new frame at %.0f ms after launch" %
                      ((now() - mono0) * 1000), flush=True)
                break
            time.sleep(0.02)
    if a.adb_port:
        serial = "127.0.0.1:%d" % a.adb_port
        # The adb server may still hold the dead connection of the old process.
        adb(["disconnect", serial])
        while now() < deadline:
            adb(["connect", serial])
            if adb_boot_completed(a.adb_port):
                print("adb sys.boot_completed=1 at %.0f ms after launch" %
                      ((now() - mono0) * 1000), flush=True)
                break
            time.sleep(0.05)
    return 0


def cmd_launch(a):
    snap = snap_dir(a.run)
    os.makedirs(snap, exist_ok=True)
    launch = {"qemu": a.qemu, "gfx_lib": a.gfx if a.gfx != "none" else "",
              "image_files": a.images, "argv": a.argv}
    launch["ids"] = describe(launch)
    write_json(os.path.join(snap, "launch.json"), launch)
    return 0


def cmd_discard(a):
    snap = snap_dir(a.run)
    for f in ("state.bin", "state.tmp", "manifest.json", "ram.img", "as.img",
              "last-frame.png"):
        try:
            os.unlink(os.path.join(snap, f))
        except FileNotFoundError:
            pass
    shutil.rmtree(os.path.join(snap, "gfx"), ignore_errors=True)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("command", choices=["launch", "status", "check", "suspend",
                                       "resume", "restore", "discard"])
    p.add_argument("--run", required=True, help="run directory")
    p.add_argument("--launch", help="launch.json (default: in snapshot dir)")
    p.add_argument("--quit", action="store_true", help="suspend: quit QEMU")
    p.add_argument("--timeout", type=float, default=60.0)
    p.add_argument("--adb-port", type=int)
    p.add_argument("--frame-dir")
    p.add_argument("--t0", type=float, help="restore: launch time (epoch s)")
    p.add_argument("--qemu")
    p.add_argument("--gfx", default="none")
    p.add_argument("--images", nargs="*", default=[])
    argv = []
    if "--" in sys.argv:
        i = sys.argv.index("--")
        argv, sys.argv = sys.argv[i + 1:], sys.argv[:i]
    a = p.parse_args()
    a.argv = argv
    a.run = os.path.abspath(a.run)
    return {"launch": cmd_launch, "status": cmd_status, "check": cmd_check,
            "suspend": cmd_suspend,
            "resume": cmd_resume, "restore": cmd_restore,
            "discard": cmd_discard}[a.command](a)


if __name__ == "__main__":
    sys.exit(main())
