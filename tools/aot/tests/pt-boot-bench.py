#!/usr/bin/env python3
"""Boot milestone timer for the passthrough measurements (run names pt-*).

Same measurement as tools/aot/boot-bench.py (wall clock since launch and the
guest kernel timestamp of each milestone in serial.log, fresh userdata, virt
board, tools/run-macos.sh --tcg), which only accepts aot* run names; this one
only accepts pt-* names, so that it can never touch another agent's run, and
also records the host load average before and after the run.

  tools/aot/tests/pt-boot-bench.py --qemu BIN --name pt-X [--timeout 1800]
        [--stop-after surfaceflinger] [--adb-port 5651] [--env K=V ...]
        [--json out.json] [-- extra qemu args]
"""
import argparse, json, os, re, signal, subprocess, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
MILESTONES = [
    ("run_init", "Run /init as init process"),
    ("second_stage", "init second stage started"),
    ("zygote", "starting service 'zygote'"),
    ("surfaceflinger", "starting service 'surfaceflinger'"),
]
TS = re.compile(r"^\[\s*([0-9]+\.[0-9]+)\]")


def loadavg():
    return [float(x) for x in subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True,
                                             text=True).stdout.strip(" {}\n").split()[:3]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--stop-after", default="surfaceflinger")
    ap.add_argument("--adb-port", default="5651")
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--json")
    ap.add_argument("--machine", default="virt")
    ap.add_argument("extra", nargs="*")
    a = ap.parse_args()
    assert a.name.startswith("pt-"), "run names must start with pt-"
    env = dict(os.environ, QEMU=a.qemu)
    for kv in a.env:
        k, v = kv.split("=", 1)
        env[k] = v
    run = os.path.join(ROOT, "engine", "run", a.name)
    serial = os.path.join(run, "serial.log")
    cmd = [os.path.join(ROOT, "tools", "run-macos.sh"), "--fresh", "--tcg", "--machine", a.machine,
           "--name", a.name, "--adb-port", a.adb_port, "--timeout", str(a.timeout + 60)]
    if a.extra:
        cmd += ["--"] + a.extra
    for stale in ("serial.log", "logcat.log"):
        try:
            os.remove(os.path.join(run, stale))
        except FileNotFoundError:
            pass
    load0 = loadavg()
    t0 = time.time()
    proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    seen, stop_at, pos, buf = {}, None, 0, ""
    while True:
        now = time.time() - t0
        if os.path.exists(serial):
            with open(serial, "r", errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
            lines = (buf + chunk).split("\n")
            buf = lines.pop()
            for line in lines:
                for key, pat in MILESTONES:
                    if key not in seen and pat in line:
                        m = TS.match(line)
                        seen[key] = {"wall": round(now, 2), "guest": float(m.group(1)) if m else None}
                        print(f"{a.name}: {key:15s} wall={now:8.2f}s guest={seen[key]['guest']}", flush=True)
                        if key == a.stop_after:
                            stop_at = now
        if stop_at is not None and now >= stop_at:
            break
        if now > a.timeout or proc.poll() is not None:
            break
        time.sleep(0.25)
    load1 = loadavg()
    # Stop only the QEMU of this run (its command line names engine/run/<name>/).
    for pid in subprocess.run(["pgrep", "-f", f"engine/run/{a.name}/"], capture_output=True,
                              text=True).stdout.split():
        try:
            os.kill(int(pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    res = {"name": a.name, "qemu": a.qemu, "env": a.env, "milestones": seen,
           "elapsed": round(time.time() - t0, 2), "loadavg_start": load0, "loadavg_end": load1}
    print(json.dumps(res))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(res, f, indent=1)


if __name__ == "__main__":
    main()
