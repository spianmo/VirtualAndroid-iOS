#!/usr/bin/env python3
"""Scripted guest session for AOT profiling, capture and benchmarking.

  workload.py --serial 127.0.0.1:PORT [--scale 1] [--json out.json]
              [--boot-timeout 3600] [--quit-monitor RUN/monitor.sock]

Waits for sys.boot_completed=1 and the launcher, then runs a fixed sequence
of UI actions through adb (Settings and two of its pages, app drawer,
notification shade, the AOSP apps that are installed) and records how long
each step took. The same sequence drives the tbprof profile (JIT), the AOT
capture (TCTI) and the TCTI vs TCTI+AOT comparison, so the TBs captured are
the ones the profile ranked. --scale stretches the settle times for slow
backends (TCTI: about 5). With --quit-monitor the VM is stopped at the end.
"""
import argparse, json, os, re, socket, subprocess, sys, time

ADB = "adb"
APPS = [  # (label, package); launched through their LAUNCHER activity if installed
    ("contacts", "com.android.contacts"),
    ("dialer", "com.android.dialer"),
    ("messaging", "com.android.messaging"),
    ("calendar", "com.android.calendar"),
    ("deskclock", "com.android.deskclock"),
    ("gallery", "com.android.gallery3d"),
    ("files", "com.android.documentsui"),
    ("camera", "com.android.camera2"),
    ("browser", "org.chromium.webview_shell"),
]


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


class Guest:
    def __init__(self, serial, scale):
        self.serial = serial
        self.scale = scale

    def adb(self, *args, timeout=600):
        try:
            p = subprocess.run([ADB, "-s", self.serial, *args], capture_output=True, text=True,
                               timeout=timeout)
            return p.returncode, p.stdout
        except subprocess.TimeoutExpired:
            return -1, ""

    def sh(self, cmd, timeout=600):
        return self.adb("shell", cmd, timeout=timeout)[1]

    def settle(self, s):
        time.sleep(s * self.scale)


def wait_boot(g, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        subprocess.run([ADB, "connect", g.serial], capture_output=True, text=True, timeout=30)
        rc, out = g.adb("shell", "getprop sys.boot_completed", timeout=30)
        if rc == 0 and out.strip() == "1":
            return time.time() - t0
        time.sleep(3)
    return None


def wait_focus(g, pat, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        out = g.sh("dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'", timeout=120)
        if re.search(pat, out):
            return time.time() - t0
        time.sleep(1)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--boot-timeout", type=int, default=3600)
    ap.add_argument("--json")
    ap.add_argument("--quit-monitor")
    a = ap.parse_args()
    g = Guest(a.serial, a.scale)
    res = {"serial": a.serial, "scale": a.scale, "steps": []}
    t_start = time.time()

    def step(label, fn):
        t0 = time.time()
        extra = fn() or {}
        dt = round(time.time() - t0, 2)
        res["steps"].append({"step": label, "secs": dt, **extra})
        log(f"{label:24s} {dt:8.2f}s {extra if extra else ''}")

    def start(component=None, action=None):
        arg = f"-n {component}" if component else f"-a {action}"
        out = g.sh(f"am start -W {arg}")
        m = re.search(r"TotalTime: (\d+)", out)
        return {"total_ms": int(m.group(1))} if m else {"am": out.strip()[-120:]}

    boot = wait_boot(g, a.boot_timeout)
    res["boot_completed_wait"] = boot
    log(f"boot_completed after {boot}s of waiting")
    if boot is None:
        sys.exit(1)
    res["launcher_wait"] = wait_focus(g, r"launcher3|Launcher", 900 * a.scale)
    log(f"launcher focused after {res['launcher_wait']}s")
    g.settle(10)

    swipe_up = "input swipe 540 1800 540 600 300"
    swipe_down = "input swipe 540 600 540 1800 300"
    step("settings", lambda: start("com.android.settings/.Settings"))
    g.settle(3)
    for i in range(3):
        step(f"settings_scroll{i}", lambda: (g.sh(swipe_up), g.settle(1.5), None)[-1])
    for act in ("android.settings.DISPLAY_SETTINGS", "android.settings.WIFI_SETTINGS",
                "android.settings.APPLICATION_SETTINGS"):
        step(act.split(".")[-1].lower(), lambda act=act: start(action=act))
        g.settle(3)
        g.sh(swipe_up)
        g.settle(1.5)
    step("home", lambda: (g.sh("input keyevent KEYCODE_HOME"), g.settle(3), None)[-1])
    step("app_drawer", lambda: (g.sh("input swipe 540 2000 540 500 250"), g.settle(4),
                                g.sh(swipe_up), g.settle(2), None)[-1])
    g.sh("input keyevent KEYCODE_HOME")
    g.settle(3)
    step("notif_shade", lambda: (g.sh("cmd statusbar expand-notifications"), g.settle(3),
                                 g.sh("cmd statusbar expand-settings"), g.settle(3),
                                 g.sh("cmd statusbar collapse"), g.settle(2), None)[-1])
    installed = set(re.findall(r"package:(\S+)", g.sh("pm list packages")))
    res["apps"] = []
    for label, pkg in APPS:
        if pkg not in installed:
            continue
        comp = g.sh(f"cmd package resolve-activity --brief -c android.intent.category.LAUNCHER {pkg}")
        comp = comp.strip().splitlines()[-1] if comp.strip() else ""
        if "/" not in comp:
            continue
        res["apps"].append(label)
        step(f"app_{label}", lambda comp=comp: start(comp))
        g.settle(4)
        g.sh(swipe_up)
        g.settle(2)
        g.sh(swipe_down)
        g.settle(2)
        g.sh("input keyevent KEYCODE_HOME")
        g.settle(3)
    # second launch of Settings: warm start
    step("settings_warm", lambda: start("com.android.settings/.Settings"))
    g.settle(3)
    g.sh("input keyevent KEYCODE_HOME")
    g.settle(5)
    res["total"] = round(time.time() - t_start, 2)
    log(f"done in {res['total']}s")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(res, f, indent=1)
    if a.quit_monitor:
        s = socket.socket(socket.AF_UNIX)
        s.connect(a.quit_monitor)
        s.sendall(b"quit\n")
        time.sleep(1)
        s.close()


if __name__ == "__main__":
    main()
