#!/usr/bin/env python3
"""Boot benchmark: run tools/run-macos.sh with a given QEMU binary and record
when each boot milestone appears in serial.log (wall clock since launch and
the guest kernel timestamp).

  tools/aot/boot-bench.py --qemu BIN --name aot-jit [--timeout 1800]
                          [--stop-after surfaceflinger] [--linger 0]
                          [--env K=V ...] [--json out.json] [-- extra qemu args]

Stops the VM (only the one it started) once the --stop-after milestone is seen
(+ --linger seconds) or at --timeout.
"""
import argparse, json, os, re, signal, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MILESTONES = [
    ("run_init", "Run /init as init process"),
    ("second_stage", "init second stage started"),
    ("zygote", "starting service 'zygote'"),
    ("surfaceflinger", "starting service 'surfaceflinger'"),
]
TS = re.compile(r"^\[\s*([0-9]+\.[0-9]+)\]")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--stop-after", default="surfaceflinger")
    ap.add_argument("--linger", type=int, default=0)
    ap.add_argument("--adb-port", default="5641")
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--json")
    ap.add_argument("--machine", default="virt")
    ap.add_argument("--watch", default="", help="also stop when this text appears in logcat.log (count:N)")
    ap.add_argument("extra", nargs="*")
    a = ap.parse_args()
    assert a.name.startswith("aot") or a.name == "tcti-repro", "run names must start with aot"
    hold = os.path.join(ROOT, ".logs", "HOLD_VMS")
    while os.path.exists(hold):          # other session needs a quiet machine
        print("HOLD_VMS present, waiting", flush=True)
        time.sleep(20)

    env = dict(os.environ, QEMU=a.qemu)
    for kv in a.env:
        k, v = kv.split("=", 1)
        env[k] = v
    run = os.path.join(ROOT, "engine", "run", a.name)
    serial = os.path.join(run, "serial.log")
    cmd = [os.path.join(ROOT, "tools", "run-macos.sh"), "--fresh", "--tcg", "--machine", a.machine, "--name", a.name,
           "--adb-port", a.adb_port, "--timeout", str(a.timeout + 60)]
    if a.extra:
        cmd += ["--"] + a.extra
    for stale in ("serial.log", "logcat.log"):   # never read a previous run's logs
        try:
            os.remove(os.path.join(run, stale))
        except FileNotFoundError:
            pass
    t0 = time.time()
    proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    seen = {}
    stop_at = None
    pos = 0
    buf = ""
    while True:
        now = time.time() - t0
        if os.path.exists(serial):
            with open(serial, "r", errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
            buf += chunk
            lines = buf.split("\n")
            buf = lines.pop()
            for line in lines:
                for key, pat in MILESTONES:
                    if key not in seen and pat in line:
                        m = TS.match(line)
                        seen[key] = {"wall": round(now, 2), "guest": float(m.group(1)) if m else None}
                        print(f"{a.name}: {key:15s} wall={now:8.2f}s guest={seen[key]['guest']}", flush=True)
                        if key == a.stop_after:
                            stop_at = now + a.linger
        if stop_at is not None and now >= stop_at:
            break
        if os.path.exists(hold):
            print(f"{a.name}: HOLD_VMS appeared, stopping", flush=True)
            seen["held"] = {"wall": round(now, 2), "guest": None}
            break
        if a.watch:
            pat, _, cnt = a.watch.rpartition(":")
            lc = os.path.join(run, "logcat.log")
            if os.path.exists(lc):
                with open(lc, errors="replace") as f:
                    n = f.read().count(pat)
                if n >= int(cnt) and "watch" not in seen:
                    seen["watch"] = {"wall": round(now, 2), "guest": None, "count": n}
                    print(f"{a.name}: watch '{pat}' x{n} wall={now:.1f}", flush=True)
                    stop_at = now + 2
        if now > a.timeout or proc.poll() is not None:
            break
        time.sleep(0.25)
    # Stop the QEMU we started: it runs in our session; match the run dir to be safe.
    out = subprocess.run(["pgrep", "-f", f"engine/run/{a.name}/"], capture_output=True, text=True).stdout.split()
    for pid in out:
        try:
            os.kill(int(pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        pass
    try:  # also reap run-macos.sh's sleeper subshell (same session, started by us)
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    res = {"name": a.name, "qemu": a.qemu, "env": a.env, "milestones": seen,
           "elapsed": round(time.time() - t0, 2)}
    print(json.dumps(res))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(res, f, indent=1)


if __name__ == "__main__":
    main()
