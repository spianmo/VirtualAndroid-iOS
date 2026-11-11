#!/usr/bin/env python3
"""Scripted guest session for AOT profiling, capture and benchmarking.

  workload.py --serial 127.0.0.1:PORT [--scale 1] [--json out.json]
              [--boot-timeout 3600] [--quit-monitor RUN/monitor.sock]
              [--steady-rounds 3] [--steady-only] [--qmp RUN/qmp.sock [--touch-hz 60]]

Waits for sys.boot_completed=1 and the launcher, then runs a fixed sequence
of UI actions through adb (Settings and two of its pages, app drawer,
notification shade, the AOSP apps that are installed) and records how long
each step took. The same sequence drives the tbprof profile (JIT), the AOT
capture (TCTI) and the TCTI vs TCTI+AOT comparison, so the TBs captured are
the ones the profile ranked. --scale stretches the settle times for slow
backends (TCTI: about 5). With --quit-monitor the VM is stopped at the end.

After that, --steady-rounds rounds (default 3, 0 = none) of the steady-state
UI that decides the frame rate once everything is loaded: scrolling the
Settings home page and the app list, opening and closing the app drawer, the
notification shade and quick settings (by gesture and by command), recents
(switching between tasks), and typing on the LatinIME soft keyboard into the
launcher's app search and the Settings search. Each steady step resets and
then records `dumpsys gfxinfo` of the package that draws it (frames,
janky frames, frame time percentiles) in the step's "gfx" entry.
--steady-only skips the cold-start sequence (benchmarking a booted guest).

Before every step and every key event, system error dialogs are answered
(ANR: "Wait", crash: "Close app") and listed in "dialogs": under TCTI
SystemUI's first start gets an ANR dialog, and a HOME or recents key while it
is up closes it as "Close app", which kills SystemUI (Guest.dismiss_dialogs).

With --qmp (the QMP socket of the VM: run-macos.sh and run_sim.sh create
RUN/qmp.sock) swipes and taps are injected from the host into the virtio
multitouch device, as the app does, instead of `adb shell input`, whose
per-gesture `input`/`cmd` processes are a large share of the guest's CPU under
TCTI and inflate the measured jank. Key events, text and everything else still
go through adb. Use it for frame-rate measurements.

Coordinates assume the default 1080x2340 display at 440 dpi with 3-button
navigation (images/android-33), as do the old steps' swipes.
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
SETTINGS = "com.android.settings"
LAUNCHER = "com.android.launcher3"
SYSTEMUI = "com.android.systemui"
LATINIME = "com.android.inputmethod.latin"
SEARCH_PKG = "com.android.settings.intelligence"

# LatinIME QWERTY key centres (portrait 1080x2340, 440 dpi, 3-button nav)
KEY_ROWS = ((1617, 54, "qwertyuiop"), (1784, 108, "asdfghjkl"), (1948, 216, "zxcvbnm"))
KEY_W = 108
KEY_SPACE = (540, 2106)
KEY_DEL = (1004, 1948)
KEYS = {c: (x0 + KEY_W * i, y) for y, x0, row in KEY_ROWS for i, c in enumerate(row)}
KEYS[" "] = KEY_SPACE

# dumpsys gfxinfo summary lines (first block = whole process)
GFX_RE = (("frames", r"Total frames rendered: (\d+)"),
          ("janky", r"Janky frames: (\d+)"),
          ("p50_ms", r"\n50th percentile: (\d+)ms"),
          ("p90_ms", r"\n90th percentile: (\d+)ms"),
          ("p99_ms", r"\n99th percentile: (\d+)ms"),
          ("gpu_p50_ms", r"50th gpu percentile: (\d+)ms"),
          ("gpu_p90_ms", r"90th gpu percentile: (\d+)ms"))


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


class QMPTouch:
    """Touch from the host, like the app's touches: QMP input-send-event "mtt" and
    "btn" events into the guest's virtio multitouch device (the only multi-touch
    handler on ranchu). `adb shell input swipe/tap` instead starts the `input`
    and `cmd` processes in the guest for every gesture, and under TCTI they cost
    more guest CPU than the UI being measured (one per swipe, about a third of the
    busy time while scrolling)."""

    ABS_MAX = 0x7fff          # INPUT_EVENT_ABS_MAX, the device's axis range

    def __init__(self, path, width=1080, height=2340, hz=60):
        self.width, self.height, self.hz = width, height, hz
        self.tracking = 0
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(30)
        self.s.connect(path)
        self.f = self.s.makefile("rwb", buffering=0)
        self._reply()                                    # greeting
        self._cmd("qmp_capabilities")

    def _reply(self):
        while True:
            line = self.f.readline()
            if not line:
                raise ConnectionError("QMP closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            if "error" in msg:
                raise RuntimeError(f"QMP: {msg['error']}")
            return msg

    def _cmd(self, execute, **args):
        msg = {"execute": execute}
        if args:
            msg["arguments"] = args
        self.f.write(json.dumps(msg).encode() + b"\n")
        return self._reply()

    def _axis(self, v, size):
        return max(0, min(self.ABS_MAX, round(v * self.ABS_MAX / (size - 1))))

    def _send(self, kind, x=None, y=None):
        # QAPI wants axis/value on every mtt event; the device only uses them for "data".
        def mtt(type, axis="x", value=0, tracking=None):
            return {"type": "mtt", "data": {"type": type, "slot": 0, "axis": axis, "value": value,
                                            "tracking-id": self.tracking if tracking is None else tracking}}
        ev = []
        if kind != "end":
            ev.append(mtt(kind))                                   # ABS_MT_SLOT + ABS_MT_TRACKING_ID
            ev.append(mtt("data", "x", self._axis(x, self.width)))
            ev.append(mtt("data", "y", self._axis(y, self.height)))
            if kind == "begin":
                ev.append({"type": "btn", "data": {"button": "touch", "down": True}})
        else:
            ev.append(mtt("end", tracking=-1))
            ev.append({"type": "btn", "data": {"button": "touch", "down": False}})
        self._cmd("input-send-event", events=ev)      # ends with a SYN_REPORT

    def swipe(self, x0, y0, x1, y1, ms=300):
        """Finger down at (x0, y0), moves at `hz` to (x1, y1) over `ms`, up: what
        `input swipe` does, in real time."""
        self.tracking = (self.tracking + 1) & 0xffff
        t0 = time.monotonic()
        self._send("begin", x0, y0)
        dur = max(ms, 1) / 1000.0
        step = 1.0 / self.hz
        k = 1
        while True:
            t = t0 + k * step
            if t >= t0 + dur:
                break
            time.sleep(max(0.0, t - time.monotonic()))
            a = (t - t0) / dur
            self._send("update", x0 + (x1 - x0) * a, y0 + (y1 - y0) * a)
            k += 1
        time.sleep(max(0.0, t0 + dur - time.monotonic()))
        self._send("update", x1, y1)
        self._send("end")

    def tap(self, x, y):
        self.tracking = (self.tracking + 1) & 0xffff
        self._send("begin", x, y)
        time.sleep(0.04)
        self._send("end")


INPUT_RE = re.compile(r"input (swipe|tap) (\d+) (\d+)(?: (\d+) (\d+)(?: (\d+))?)?")


class Guest:
    def __init__(self, serial, scale, touch=None):
        self.serial = serial
        self.scale = scale
        self.touch = touch     # QMPTouch: swipes and taps from the host
        self.t0 = time.time()
        self.dialogs = []      # system error dialogs answered (see dismiss_dialogs)

    def adb(self, *args, timeout=600):
        try:
            p = subprocess.run([ADB, "-s", self.serial, *args], capture_output=True, text=True,
                               timeout=timeout)
            return p.returncode, p.stdout
        except subprocess.TimeoutExpired:
            return -1, ""

    def sh(self, cmd, timeout=600):
        """adb shell CMD; with QMP touch, a lone `input swipe ...` / `input tap ...`
        is injected from the host instead (same coordinates and duration)."""
        m = INPUT_RE.fullmatch(cmd.strip()) if self.touch else None
        if m:
            v = [int(x) for x in m.groups()[1:] if x is not None]
            if m.group(1) == "tap" and len(v) == 2:
                self.touch.tap(*v)
                return ""
            if m.group(1) == "swipe" and len(v) >= 4:
                self.touch.swipe(*v)
                return ""
        return self.adb("shell", cmd, timeout=timeout)[1]

    def settle(self, s):
        time.sleep(s * self.scale)

    def gfx_reset(self, pkgs):
        self.sh("; ".join(f"dumpsys gfxinfo {p} reset >/dev/null" for p in pkgs))

    def gfx(self, pkgs):
        res = {}
        for p in pkgs:
            out = self.sh(f"dumpsys gfxinfo {p}", timeout=120)
            d = {}
            for k, pat in GFX_RE:
                m = re.search(pat, out)
                if m:
                    d[k] = int(m.group(1))
            if d.get("frames"):
                res[p] = d
        return res

    def dismiss_dialogs(self):
        """Answer system error dialogs: "Wait" on an ANR dialog, "Close app" on a
        crash dialog (found with uiautomator), and log them in self.dialogs.
        Under TCTI SystemUI's first start outlasts the service timeout and gets
        an ANR dialog, which comes back after "Wait" until SystemUI is done; any
        HOME or recents key while it is up closes system dialogs, which for an
        ANR dialog means "Close app" (SystemUI killed). Hence key() calls this
        first. Returns [(dialog title, button or None)]."""
        out = self.sh("dumpsys window windows | grep -E 'Window #.*(Application Not Responding|"
                      "Application Error)'", timeout=180)
        titles = re.findall(r"(Application Not Responding: [^}\s]+|Application Error: [^}\s]+)", out)
        if not titles:
            return []
        xml = self.sh("uiautomator dump /data/local/tmp/va-ui.xml >/dev/null 2>&1; "
                      "cat /data/local/tmp/va-ui.xml", timeout=300)
        done = None
        for rid in ("aerr_wait", "aerr_close"):   # the dump shows the top dialog only
            m = re.search(r'<node [^>]*resource-id="android:id/%s"[^>]*bounds="\[(\d+),(\d+)\]'
                          r'\[(\d+),(\d+)\]"' % rid, xml)
            if m:
                x0, y0, x1, y1 = map(int, m.groups())
                self.sh(f"input tap {(x0 + x1) // 2} {(y0 + y1) // 2}")
                done = rid
                self.settle(1)
                break
        found = [(t, done) for t in sorted(set(titles))]
        for t, b in found:
            self.dialogs.append({"dialog": t, "tapped": b, "t": round(time.time() - self.t0, 1)})
            log(f"dialog: {t}, tapped {b or 'nothing'}")
        return found

    def key(self, code):
        """input keyevent CODE, after answering error dialogs (dismiss_dialogs)."""
        self.dismiss_dialogs()
        self.sh(f"input keyevent {code}")

    def ime_shown(self):
        return "mInputShown=true" in self.sh("dumpsys input_method | grep mInputShown")

    def type_keys(self, text, gap=0.3):
        """Tap TEXT on the soft keyboard (falls back to `input text` without it)."""
        if not self.ime_shown():
            self.sh("input text " + text.replace(" ", "%s"))
            return False
        for c in text:
            x, y = KEYS[c]
            self.sh(f"input tap {x} {y}")
            self.settle(gap)
        return True

    def delete_keys(self, n, gap=0.2):
        for _ in range(n):
            self.sh(f"input tap {KEY_DEL[0]} {KEY_DEL[1]}")
            self.settle(gap)


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
    ap.add_argument("--steady-rounds", type=int, default=3)
    ap.add_argument("--steady-only", action="store_true")
    ap.add_argument("--qmp", help="QMP socket: inject swipes and taps from the host (QMPTouch)")
    ap.add_argument("--touch-hz", type=int, default=60, help="move events per second with --qmp")
    a = ap.parse_args()
    touch = QMPTouch(a.qmp, hz=a.touch_hz) if a.qmp else None
    g = Guest(a.serial, a.scale, touch)
    res = {"serial": a.serial, "scale": a.scale, "steady_rounds": a.steady_rounds, "steps": [],
           "dialogs": g.dialogs, "input": f"qmp {a.touch_hz} Hz" if touch else "adb input"}
    t_start = time.time()

    def step(label, fn, gfx=()):
        g.dismiss_dialogs()
        if gfx:
            g.gfx_reset(gfx)
        t0 = time.time()
        extra = fn() or {}
        dt = round(time.time() - t0, 2)
        if gfx:
            extra["gfx"] = g.gfx(gfx)
        res["steps"].append({"step": label, "secs": dt, **extra})
        log(f"{label:24s} {dt:8.2f}s {extra if extra else ''}")

    def start(component=None, action=None):
        arg = f"-n {component}" if component else f"-a {action}"
        out = g.sh(f"am start -W {arg}")
        m = re.search(r"TotalTime: (\d+)", out)
        return {"total_ms": int(m.group(1))} if m else {"am": out.strip()[-120:]}

    def home(s=3):
        g.key("KEYCODE_HOME")
        g.settle(s)

    boot = wait_boot(g, a.boot_timeout)
    res["boot_completed_wait"] = boot
    log(f"boot_completed after {boot}s of waiting")
    if boot is None:
        sys.exit(1)
    if a.steady_only:
        g.key("KEYCODE_HOME")   # a booted guest may show any app
    res["launcher_wait"] = wait_focus(g, r"launcher3|Launcher", 900 * a.scale)
    log(f"launcher focused after {res['launcher_wait']}s")
    g.settle(10)

    swipe_up = "input swipe 540 1800 540 600 300"
    swipe_down = "input swipe 540 600 540 1800 300"
    if not a.steady_only:
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
        step("home", lambda: (g.key("KEYCODE_HOME"), g.settle(3), None)[-1])
        step("app_drawer", lambda: (g.sh("input swipe 540 2000 540 500 250"), g.settle(4),
                                    g.sh(swipe_up), g.settle(2), None)[-1])
        g.key("KEYCODE_HOME")
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
            g.key("KEYCODE_HOME")
            g.settle(3)
        # second launch of Settings: warm start
        step("settings_warm", lambda: start("com.android.settings/.Settings"))
        g.settle(3)
        g.key("KEYCODE_HOME")
        g.settle(5)

    # Steady-state UI (frame rate once the apps are loaded)
    fling_up = "input swipe 540 1800 540 600 120"
    fling_down = "input swipe 540 600 540 1800 120"
    drag_up = "input swipe 540 1700 540 900 700"
    drag_down = "input swipe 540 900 540 1700 700"

    def scroll_list(n):
        for _ in range(n):
            for s in (fling_up, fling_down, drag_up, drag_down):
                g.sh(s)
                g.settle(1)

    def settings_scroll():
        g.sh("am start -W -n com.android.settings/.Settings")
        g.settle(2)
        scroll_list(3)

    def applist_scroll():
        g.sh("am start -W -a android.settings.MANAGE_ALL_APPLICATIONS_SETTINGS")
        g.settle(2)
        scroll_list(2)
        home()

    def drawer_loop():
        home(2)
        for _ in range(3):
            g.sh("input swipe 540 2000 540 500 250")    # open all apps
            g.settle(1.5)
            g.sh(fling_up)                                # overscroll
            g.settle(1)
            g.sh("input swipe 540 700 540 2000 250")    # drag it closed
            g.settle(1.5)
        home(2)

    def drawer_search():
        home(2)
        g.sh("input swipe 540 2000 540 500 250")
        g.settle(2)
        g.sh("input tap 540 200")                         # "Search apps" box
        g.settle(2)
        ok = g.type_keys("camera")
        g.settle(1)
        g.delete_keys(6)
        g.type_keys("clock")
        g.settle(1)
        home(2)
        return {"soft_keyboard": ok}

    def shade_loop():
        home(2)
        for _ in range(3):
            g.sh("input swipe 540 5 540 1400 300")       # notifications + quick quick settings
            g.settle(1.5)
            g.sh("input swipe 540 5 540 1400 300")       # full quick settings
            g.settle(1.5)
            g.sh("input swipe 540 2000 540 300 250")     # collapse
            g.settle(1.5)
            g.sh("cmd statusbar collapse")
        g.sh("cmd statusbar expand-notifications")
        g.settle(1.5)
        g.sh("cmd statusbar expand-settings")
        g.settle(1.5)
        g.sh("cmd statusbar collapse")
        g.settle(1.5)

    def recents_loop():
        g.sh("am start -W -n com.android.settings/.Settings")
        g.settle(2)
        for _ in range(3):
            g.key("KEYCODE_APP_SWITCH")
            g.settle(2)
            g.sh("input swipe 300 1200 900 1200 250")    # to the older task
            g.settle(1.5)
            g.sh("input swipe 900 1200 300 1200 250")    # back
            g.settle(1.5)
            g.sh("input tap 540 1000")                    # resume the centre task
            g.settle(2)
        home(2)

    def settings_search():
        g.sh("am start -W -a com.android.settings.action.SETTINGS_SEARCH")
        g.settle(2)
        ok = g.type_keys("display brightness")
        g.settle(2)
        g.delete_keys(10)
        g.type_keys("battery")
        g.settle(2)
        g.key("KEYCODE_BACK")
        g.settle(1)
        home(2)
        return {"soft_keyboard": ok}

    for r in range(a.steady_rounds):
        step(f"steady{r}_settings_scroll", settings_scroll, gfx=(SETTINGS,))
        step(f"steady{r}_applist_scroll", applist_scroll, gfx=(SETTINGS,))
        step(f"steady{r}_drawer", drawer_loop, gfx=(LAUNCHER,))
        step(f"steady{r}_drawer_search", drawer_search, gfx=(LAUNCHER, LATINIME))
        step(f"steady{r}_shade", shade_loop, gfx=(SYSTEMUI,))
        step(f"steady{r}_recents", recents_loop, gfx=(LAUNCHER, SETTINGS))
        step(f"steady{r}_settings_search", settings_search, gfx=(SEARCH_PKG, LATINIME))
    home(5)
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
