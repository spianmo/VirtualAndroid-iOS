# iOS / iOS Simulator build of the engine (QEMU aarch64 + deps)

Cross-compiles our QEMU (10.0.12-utm fork, `aarch64-softmmu` only) and the
minimal set of libraries it needs, as dylibs wrapped into frameworks and
xcframeworks that the app embeds and `dlopen`s. Recipe follows UTM
(`third_party/UTM/scripts/build_dependencies.sh`, `fixup.sh`), minus spice,
gstreamer, usb, tpm and all GPU libraries (agent "gfx" builds graphics).

## Rebuild

```sh
S=engine/scripts/ios
# 1. dependencies (per platform; ~3 min each, stamped, safe to re-run)
$S/build_deps.sh -p ios_simulator            # -c clean, --only glib, -x debug
$S/build_deps.sh -p ios
# 2. QEMU (per platform + TCG backend; ~10 min tcg, ~15 min tcti at NCPU=6)
$S/build_qemu.sh -p ios_simulator -b tcg  -s engine/qemu-ios   # JIT
$S/build_qemu.sh -p ios           -b tcti -s engine/qemu-ios   # no JIT
$S/build_qemu.sh -p ios_simulator -b tcti -s engine/qemu-ios   # optional: TCTI in the simulator
# 3. AOT cache for a TCTI slice (docs/AOT.md "iOS integration"); rerun after
#    every TCTI rebuild, the cache is bound to that exact binary
$S/build_aot.sh -p ios -c cap.txt --prof prof.tsv           # -> qemu-tcti/Frameworks/va_aot.framework
# 4. xcframeworks (device slice = tcti, simulator slice = tcg by default;
#    va_aot.xcframework only for TCTI slices it is bound to)
$S/make_xcframeworks.sh [--sim-backend tcg|tcti] [--device-backend tcti|tcg]
# 5. headless boot test in the simulator (no app); default machine ranchu with
#    va-vsock-pci adb bridge and gfx/build-ios-sim/dist libva_gfx
$S/run_sim.sh -b tcg --fresh --keep --screenshot-dir engine/build-ios/run/shots
adb connect 127.0.0.1:5590 && adb -s 127.0.0.1:5590 shell getprop sys.boot_completed
print quit | nc -U engine/build-ios/run/sim-tcg/monitor.sock      # stop (--keep)
#    --machine virt, --gfx-lib PATH|none, --until zygote, --timeout SECS, --adb-port N
```

`-s` picks the QEMU tree (default `engine/qemu`). Prefer `engine/qemu-ios`
(branch `ios` = master + iOS fixes, merge master into it before rebuilding):
`engine/qemu` is another agent's working tree and may be mid-edit; the script
warns when it is dirty. Missing wrap subprojects (dtc, keycodemapdb, softfloat)
are copied from `engine/qemu/subprojects`. Without the `ios` configure fix the
script patches `configure` on the fly. Env: `NCPU` (default 6), `IOS_SDKMINVER`
(15.0), `KEEP_SRC=1`.

Host requirements: Xcode 26.1 (iOS 26.1 SDKs), Homebrew meson, ninja,
pkg-config, bison (`/opt/homebrew/opt/bison/bin` is put first in PATH),
glib (for glib-mkenums), e2fsprogs (run_sim.sh), python3. `/usr/local` is
removed from PATH and pkg-config only sees the platform sysroot.

## Outputs (`engine/build-ios/`, git-ignored)

| path | content |
|---|---|
| `<plat>-arm64/sysroot` | headers, `.pc`, dylibs, static libucontext/pcre2 |
| `<plat>-arm64/Frameworks/*.framework` | dependency frameworks |
| `<plat>-arm64/qemu-<tcg\|tcti>/Frameworks/qemu-aarch64-softmmu.framework` | QEMU |
| `<plat>-arm64/qemu-<backend>/bin/va-qemu-launch` | CLI harness (dlopen + entry points) |
| `<plat>-arm64/qemu-<backend>/build` | ninja build dir (incremental rebuilds; 0.6 GB tcg, 1.4 GB tcti: safe to delete, only the build dirs of ios_simulator/tcg are kept) |
| `xcframeworks/*.xcframework` | what the app embeds; `qemu-backends.txt` says which backend each QEMU slice is |
| `run/<name>/` | run_sim.sh state: disks, `serial.log`, `logcat.log`, `qemu.out`, `milestones.txt` |

## What the app embeds

Embed & Sign these 11 xcframeworks from `engine/build-ios/xcframeworks` (QEMU's
transitive closure): `qemu-aarch64-softmmu`, `glib-2.0.0`, `gio-2.0.0`,
`gobject-2.0.0`, `gmodule-2.0.0`, `intl.8`, `iconv.2`, `ffi.8`, `pixman-1.0`,
`zstd.1`, `slirp.0`; plus gfx's `va_gfx`, `GLESv2` (ANGLE) and optionally
`MoltenVK` from `gfx/build-ios-xcframeworks` (app/scripts/embed_engine_frameworks.sh
already embeds both directories). Install names are
`@rpath/<name>.framework/<name>`, so the app needs `@executable_path/Frameworks`
in its runpath (Xcode default). QEMU does not link va_gfx: ranchu `dlopen`s it
from `-M ranchu,gfx-lib=PATH`, else `$VA_GFX_LIB`, else
`<dir of main executable>/Frameworks/va_gfx.framework/va_gfx` (the app bundle
layout), and va_gfx finds ANGLE at `../GLESv2.framework/GLESv2` next to itself.
(The app currently sets `VA_GFX_LIBRARY`, which QEMU does not read; the bundle
lookup makes it unnecessary.)
libucontext, libfdt and pcre2 are linked statically. No firmware blobs are
installed (`-kernel` boot needs none).

Sizes: QEMU framework 29 MB (tcg) / 189 MB (tcti, the gadget tables), deps 9.5 MB.

## Entry points

The dylib exports only (system/qemu.symbols plus our wildcard):
`qemu_init`, `qemu_main_loop`, `qemu_cleanup`, `bql_lock_impl`, `bql_unlock`,
`qemu_thread_create`, `replay_mutex_lock/unlock`, `g_assertion_message_expr`,
and every `va_host_*` / `va_engine_*` (host/include/va_host.h).

```c
void qemu_init(int argc, char **argv);   /* parses argv, builds the VM; returns holding the BQL */
int  qemu_main_loop(void);               /* runs until shutdown ("quit", guest poweroff); returns status */
void qemu_cleanup(int status);
```

Note the real `qemu_init` returns `void` (UTM declares it as returning int;
don't rely on a return value). Pattern (tools/va_qemu_launch.c, as UTM
`Services/UTMProcess.m` / `UTMQemuSystem.m`):

1. `dlopen(".../Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu", RTLD_NOW|RTLD_LOCAL)`, `dlsym` the three functions (and `va_host_set_callbacks` etc.).
2. Call `va_host_set_callbacks()` before `qemu_init`.
3. On a dedicated pthread (8 MB stack, QOS_CLASS_USER_INTERACTIVE) call `qemu_init` -> `qemu_main_loop` -> `qemu_cleanup` in sequence; keep the main thread free for UIKit.
4. QEMU calls `exit()` on fatal errors (bad argv, missing file) and at the end of `qemu_main`-style shutdown paths. The app must install an `atexit_b` handler that, on the QEMU thread, marks the VM as failed and `pthread_exit()`s instead of killing the app (UTM does this).
5. Stop the VM with the QMP/HMP `quit` command (or `system_powerdown`); verified: `qemu_main_loop` returns 0 and `qemu_cleanup` completes.
6. Treat the library as one VM per process: QEMU's globals are not reinitialisable after `qemu_cleanup`, and frameworks are not reliably unloadable.

Arguments: same as `tools/run-macos.sh --machine ranchu` with
`-accel tcg,thread=multi,tb-size=N -cpu cortex-a76` (see run_sim.sh), in particular:

* `-M ranchu[,gfx-lib=PATH|,gfx=off]`
* `-device va-vsock-pci,guest-cid=77,adb-port=PORT,pipe-port=5000`: the guest's
  adbd and the pipe-port services (clipboard ...) talk vsock now, so without it
  there is no adb; slirp `hostfwd` for 5555 is not needed on ranchu.
  `adb-port` listens on 127.0.0.1 inside the app process (in the simulator that
  is the Mac's loopback).
* bootconfig `androidboot.qemu.adb.pubkey=<~/.android/adbkey.pub>` (tools/make_initrd.py
  extra arg) so adbd accepts the host without a prompt (dev builds).
* Frames: install `va_host_set_present_callback()` before `qemu_init`; without
  it, `VA_DUMP_FRAMES=<dir>` (dev only) writes `frame-N.png`/`latest.png`.

Paths (disks, `-serial file:`, unix sockets) must be inside the app container;
unix socket paths must stay under 104 bytes.

## JIT, entitlements, memory

* Simulator: TCG JIT works with no entitlements. Measured with
  `tools/jit_probe.c` under `simctl spawn`: `mmap(RWX, MAP_JIT)` + the APRR
  commpage write toggle QEMU uses (`include/tcg/tcg-apple-jit.h`) runs code;
  plain RWX without MAP_JIT fails (EACCES); split W^X via `mach_vm_remap` also
  works. QEMU's default (`split-wx=off`) uses MAP_JIT. Simulator binaries are
  ad-hoc signed by the linker, no hardened runtime.
  (`pthread_jit_write_protect_np` is marked unavailable in the iOS SDK, QEMU
  does not use it.)
* Device, TCTI build: no JIT, no special entitlement; the code buffer is plain RW.
* Device, JIT build (StikDebug/sideloaded): needs a debugger attached at launch
  (`get-task-allow`; QEMU's iOS 26/TXM path does `brk #0x69` so the debugger
  prepares the region) or TrollStore `dynamic-codesigning`. Not built by default.
* Memory (device): guest RAM 2 GB + TB buffer (tb-size, 1 GB in run-macos.sh;
  use 256-512 MB on device) need `com.apple.developer.kernel.increased-memory-limit`
  and `com.apple.developer.kernel.extended-virtual-addressing` (UTM's iOS.entitlements).
* Info.plist: frameworks carry their own Info.plist (CFBundlePackageType FMWK,
  MinimumOSVersion 15.0). For the app: `UIFileSharingEnabled` /
  `LSSupportsOpeningDocumentsInPlace` if users should reach disk images.
* QEMU is built with `--disable-hvf`; UTM's `hvf-private` (jailbreak/TrollStore)
  would additionally need UTM's Hypervisor.framework shim.

## QEMU portability fixes (branch `ios`, engine/qemu-ios)

* `configure`: emit `needs_exe_wrapper = true` for TARGET_OS_IPHONE targets
  (meson otherwise thinks iOS binaries run on the macOS build host).
* `system/meson.build`: export `va_host_*` / `va_engine_*` from the darwin shared lib
  (covers every function of host/include/va_host.h incl. `va_host_set_present_callback`).

## Boot results (iOS 26.1 simulator, iPhone 17 Pro, M2 Max, headless)

### `-M ranchu` + libva_gfx (ANGLE Metal), TCG JIT, engine/qemu master 7bd3884a5

`run_sim.sh -b tcg --keep --screenshot-dir ...`, host load ~10:

| milestone | host s | guest s |
|---|---|---|
| `Run /init` | 3.1 | 1.2 |
| `init second stage started` | 7.2 | 5.3 |
| `starting service 'zygote'` | 66.8 | 65.2 |
| `starting service 'surfaceflinger'` | 69.9 | 68.5 |
| `starting service 'bootanim'` | 75.0 | 73.6 |
| bootanim exits / `sys.boot_completed=1` | 156.9 | 155.0 |

Renderer: `ANGLE Metal Renderer: Apple iOS simulator GPU`, guest GLES 3.0,
zero-copy IOSurface frames; `first guest frame 1080x2340`; frame dumps show the
boot animation and then the Launcher3 home screen (a "System UI isn't
responding" dialog appears once under TCG, HOME dismisses it).
`adb connect 127.0.0.1:5590` from macOS works: `getprop sys.boot_completed` = 1,
focus `com.android.launcher3/.uioverrides.QuickstepLauncher`. All pipe services
the guest opens are found (opengles, GLProcessPipe, refcount, qemud
boot-properties/gps/sensors/camera/fingerprintlisten, clipboard, QemuMiscPipe).
Known: after `quit`, `qemu_cleanup` completes but the process then aborts in a
va_gfx worker thread (`ProcessCleanupThread` -> `~ShaderParser` heap checksum)
during `exit()`; reported to gfx.

### earlier, before the ranchu board (`-M virt`, no graphics)

`run_sim.sh --fresh --until surfaceflinger`, `-smp 4 -m 2048 -cpu cortex-a76
-accel tcg,thread=multi,tb-size=1024`, host load ~10 (other agents building).
Times are host seconds since `simctl spawn` (guest kernel timestamp nearly equal).

| milestone | TCG JIT (`-M virt`) | TCTI (`-M virt`) | TCG JIT (`-M ranchu`, load ~130) |
|---|---|---|---|
| `Run /init` | 3.1 s | 8.2 s | 5.4 s |
| `init second stage started` | 7.2 s | 18.7 s | 11.9 s |
| `starting service 'zygote'` | 68.7 s | 390.7 s | 106.5 s |
| `starting service 'surfaceflinger'` | 69.7 s | 410.4 s | 109.6 s |

TCTI is ~5.7x slower than the JIT to zygote. Beyond zygote the guest loops:
hwcomposer/gralloc/surfaceflinger abort on `HostConnection: Failed to connect
to host (QemuPipeStream)` and zygote restarts (no `opengles` pipe service /
gfxstream yet; same state as the macOS HVF build). With `-M ranchu` the guest
opens goldfish pipe services (`android_pipe_connect` trace: qemud
boot-properties/sensors, opengles) which are not implemented yet (`found=0`).
`quit` on the monitor makes `qemu_main_loop` return 0 and `qemu_cleanup` finish.
