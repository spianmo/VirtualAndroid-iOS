# JIT on the iPhone (StikDebug)

The device app carries two engines and picks one at launch:

| engine | framework | when |
|---|---|---|
| TCG JIT (QEMU's aarch64 backend, split W^X) | `qemu-aarch64-softmmu` | the app was opened from StikDebug (a debugger is attached) and the JIT option is on (default) |
| TCTI + AOT cache | `qemu-aarch64-softmmu-tcti` + `va_aot` | opened from the home screen, option off, or the last JIT start failed |

Both are built from the same engine/qemu-ios tree with the same devices, so one
snapshot (M4 fast resume) serves both: suspend under one engine, resume under
the other.

## Why a debugger is needed (iOS 26+, TXM)

A sideloaded app cannot create executable pages. A debugger attach sets
`CS_DEBUGGED`; before iOS 26 that alone allowed QEMU's split W^X code buffer
(an RX mapping plus an RW `mach_vm_remap` alias, `-accel tcg,split-wx=on`).
On devices with TXM (Trusted Execution Monitor: A15/M2 and later on iOS 26,
every device but iPad8,11/8,12 on iOS 27) the process still cannot make its
own pages executable. The attached debugger has to touch every page of the
RX mapping (debugserver `M` writes, which TXM accepts), and only while it is
attached. So the debugger must still be attached when QEMU allocates its code
buffer (`tcg_region_init`, during `qemu_init`).

## The protocol (engine/qemu-ios `tcg/region.c`)

StikDebug 3.2 runs a JavaScript per app; the default for unknown apps is
`universal.js`. Its "JIT26" calls are `mov x16, #cmd; brk #0xf00d`:
0 = detach, 1 = prepare region (x0 = address or 0, x1 = length, returns
x0), 2 = load more script. The older protocol (UTM, StikDebug `legacy.js`) is
a single `brk #0x69` with x0/x1, after which the script detaches. The engine
speaks both:

1. `brk #0x69` with the RX alias and the length.
2. Debugger gone afterwards and x0 unchanged: `legacy.js` prepared and
   detached. Done.
3. Still attached and x0 changed: `universal.js` refused the legacy call. It
   means to return 0xE0000069, but its 4-byte `P0=E0000069` packet is padded
   by debugserver with 0xcc, so x0 comes back as 0xcccccccc690000e0. The
   engine then sends `x16=1; brk #0xf00d` (prepare; x0 must come back as the
   address), then `x16=0; brk #0xf00d` (detach).
4. Still attached, x0 unchanged: an unknown script handled `brk #0x69` and
   stays attached; nothing more is sent.

Then the engine reads the first byte of every 16 KiB page through the RX
view: StikDebug (and the lldb stand-in) write 0x69 there, the mapping starts
zero-filled. Some but not all pages marked means the session broke off
midway (VPN drop, StikDebug killed); that and any protocol failure make
`qemu_init` fail with a clear error instead of a crash minutes later when
code is first written to an unprepared page. A region above 64 GB is refused
before any brk. While a call is in flight a SIGTRAP handler skips our own
`brk` if the debugger detached in between (otherwise the process would die).
Finally the engine writes through the RW view and reads through the RX view
(both ends of the buffer): a debugger write that fell back to `VM_PROT_COPY`
would have split the two views.

After the detach the region stays executable. Detaching matters: attached,
the app stops in the debugger on every signal and dies when StikDebug's
connection drops.

StikDebug prepares by writing one byte (0x69) at the start of every 16 KiB
page, 128 pipelined `$M<addr>,1:69` packets per round trip
(`JSDebugSupport.swift`), and encodes addresses with 9 hex digits: the region
must lie below 64 GB. The engine warns if it does not (the buffer is
allocated early in `qemu_init`; on the iPhone it landed at 0x145a40000). The
writes make every page of the buffer resident.

`VA_JIT26` (app: `-VAJIT26 auto|universal|legacy|none`) forces one protocol;
`none` skips the brk, for Xcode's debugger, which would stop on it.

## Opening the app

- From StikDebug: pick VirtualAndroid, enable JIT. StikDebug 3.2 runs a
  script only when one is assigned (TXM devices): long-press VirtualAndroid,
  "Assign Script", `universal.js` (`legacy.js` also works). Without a script
  StikDebug just attaches and detaches; the app notices the debugger left
  before the engine started and uses TCTI.
- From the home screen (default "Ask StikDebug for JIT ..." on): before
  auto-booting, the app opens
  `stikjit://enable-jit?bundle-id=dev.virtualandroid.app&pid=<pid>&script-name=universal.js`.
  StikDebug (confirm the "Enable JIT?" dialog) attaches to the running app
  with universal.js and switches back; the app waits until the debugger is
  attached (20 s in front at most, "Start without JIT" / Start skip it), then
  boots with JIT; without a debugger it boots TCTI. Every home-screen launch
  asks again; turn "Ask StikDebug for JIT ..." off to stop that.

## App side

- `QemuEngine.jitDecision` (pure logic in `JITDecision`, unit-tested): sampled
  once at launch from `csops` (CS_DEBUGGED), `sysctl` (P_TRACED) and the TXM
  table (StikDebug's rule). JIT iff the option is on, the JIT engine is
  embedded, CS_DEBUGGED is set and, on a TXM device, the debugger is still
  attached.
- No JIT although StikDebug attached for it (option off, last start failed):
  `va_runtime_release_jit_debugger()` sends `brk #0x69` with an empty region
  (legacy.js detaches) and, if `universal.js` answered, the detach call.
- The decision is re-sampled until the engine starts (`refreshJITDecision`):
  after a StikDebug request, and in `QemuEngine.start`. A debugger that came
  but cannot be used this launch is released right away.
- JIT start marker `jit-start.pending` (app support dir): written before a JIT
  engine starts, removed once a guest frame arrives or the kernel console
  grows. Found at the next launch, that launch uses TCTI once and says so (and
  does not ask StikDebug).
- A JIT engine that dies in `qemu_init` (region not prepared) before QEMU read
  the snapshot leaves the snapshot alone; the next launch restores it.
- Feature probes (snapshots, Wi-Fi, Bluetooth, audio) read an embedded engine
  binary independent of the JIT decision.
- Snapshot identity: hash of both engine binaries; the argv hash ignores
  `tb-size` and `split-wx`.
- The engine's stderr goes to `vms/default/qemu.out` on the device
  (`VA_STDERR_FILE`; `-VAStderrConsole YES` keeps the console), so the line
  `tcg: JIT region ... prepared by the debugger (... protocol) in N s` is there.
- Start screen: "JIT when opened from StikDebug" (takes effect at the next
  launch) and a line saying what this launch runs and why.

## Build

```sh
S=engine/scripts/ios
$S/build_qemu.sh -p ios -b tcg  -s engine/qemu-ios     # device JIT engine (~5 min)
$S/build_qemu.sh -p ios -b tcti -s engine/qemu-ios     # device TCTI engine (+ build_aot.sh for its cache)
$S/make_xcframeworks.sh --device-backend tcg+tcti     # JIT primary + TCTI secondary (renamed) + va_aot
```

`tcg+tcti` copies the TCTI framework to `qemu-aarch64-softmmu-tcti.framework`
(install name, executable and bundle id changed; the code and so the AOT
binding are untouched). The app then embeds both (`embed_engine_frameworks.sh`
embeds every xcframework).

## Setting up StikDebug on a phone

1. Install StikDebug: the IPA ships unsigned; sign it with a development
   certificate and a profile for its bundle id (a wildcard profile works; it
   needs no special entitlement) and install it with `devicectl device install app`.
2. Pairing file: the Mac's lockdown pair record for the phone, read from
   usbmuxd (`ReadPairRecord`, no root needed) plus a `UDID` key, copied to
   StikDebug's `Documents/pairingFile.plist`
   (`devicectl device copy to --domain-type appDataContainer --domain-identifier com.stik.stikdebug`);
   StikDebug moves it into `Application Support/Pairing/`. Or import it in the app.
3. Install LocalDevVPN from the App Store and turn it on (StikDebug reaches
   the phone's own lockdownd through it).
4. StikDebug also downloads and mounts the Developer Disk Image itself
   (cryptex method on iOS 26.4+, needs internet once); wait for "Tunnel
   connected" and the DDI mount after (re)opening it.
5. Pairing file format: StikDebug 3.2 reads it with `rp_pairing_file_read`,
   which wants RemotePairing keys (`public_key`, `private_key`,
   `identifier`). A plain lockdown record (what usbmuxd `ReadPairRecord`
   returns, and what the file pushed on 2026-11-11 is) is rejected with
   "missing field public_key". Make a RemotePairing file with StikDebug's own
   on-device pairing (Settings -> Pairing File -> Pair a Device -> Pair iPhone
   or iPad, then iOS Settings -> Privacy & Security -> Developer Mode -> "Pair
   with StikDebug-xxxxxx"), or with iloader / idevice_pair (Remote kind) on the
   Mac.
6. Assign `universal.js` to VirtualAndroid (above), or open VirtualAndroid
   from the home screen and let it ask StikDebug.

Without StikDebug, for development: launch the app stopped
(`devicectl device process launch --start-stopped`) and attach
`tools/jit/jit_host.py` from a Mac (`xcrun lldb -o "command script
import tools/jit/jit_host.py" -o "vajit <device-id> <pid>"`). It speaks the same
protocol over USB (one page per lldb round trip: 215-222 s for 512 MB).

## Measurements (iPhone 17 Pro Max, iOS 27.2, 2026-11-11)

Same userdata (not prebaked; CoolApk and Xiaohongshu installed, both `verify`
compiled), `-smp 4`, 2 GB guest, 512 MB code buffer. The JIT run used the Mac
lldb stand-in for StikDebug (`tools/jit/jit_host.py`, the same
universal.js protocol over USB); TCTI + AOT restored the snapshot that the JIT
run saved (cross-engine restore works: adb back 4 s after launch). Every app
start and the scroll run from a quiet guest: all third-party apps
force-stopped, 1-min load average below 3 (`am start -W` TotalTime, ms;
`tools/jit/appstarts.sh` and `tools/jit/scroll.sh` over the guest adb).

| | JIT | TCTI + AOT | speedup |
|---|---|---|---|
| Settings | 1557 | 2500 | 1.6x |
| DeskClock | 1295 | 2214 | 1.7x |
| Calendar | 888 | 1623 | 1.8x |
| Dialer | 1177 | 2227 | 1.9x |
| CoolApk (`com.coolapk.market`) | 16750 | 35415 | 2.1x |
| Xiaohongshu (`com.xingin.xhs`) | 13646 | 26739 | 2.0x |
| Settings scroll: frames / janky | 810 / 1.85 % | 883 / 3.5 % | |
| Settings scroll p50 / p90 / p99 frame time | 18 / 21 / 27 ms | 21 / 25 / 34 ms | |

Cold boot under JIT (after the debugger detached): kernel to init second stage
4.9 s, zygote 44.6 s (odsign waited 28 s for odrefresh compiling the 32-bit
boot classpath, a one-off because this userdata had no ART cache), preload
4.5 s, `enable_screen` 69.9 s, `sys.boot_completed` 83 s. The same boot under
TCTI + AOT: zygote 154 s, `boot_completed` 433 s (fresh userdata, docs/AOT.md).

The system UI is mostly in the AOT cache, so scrolling gains little; app code
(native libraries, ART JIT output, dex2oat) is never in the cache and runs
about twice as fast under JIT. With two big apps running the 2 GB guest
swaps (zram 690 MB used, kswapd at 66 % of a vCPU), so measure from a quiet
guest. The process had 5.9 GB available (`os_proc_available_memory`, logged
at engine start), so a 3 GB guest would fit; not tried yet.

Code buffer preparation: the lldb stand-in writes one page per round trip
(4-8 ms per page, 215 s for 512 MB); StikDebug pipelines 128 writes per round
trip, so expect a small fraction of that (to be measured with StikDebug).
