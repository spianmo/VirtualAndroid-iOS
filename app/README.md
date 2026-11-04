# VirtualAndroid iOS app

SwiftUI app that hosts the engine (QEMU + ranchu board + goldfish services +
libva_gfx) in-process, shows guest frames with Metal, and bridges Android
hardware to iOS through `host/include/va_host.h`.

## Build and run

```sh
brew install xcodegen                      # project.yml -> VirtualAndroid.xcodeproj
cd app && xcodegen generate && cd ..
xcodebuild -project app/VirtualAndroid.xcodeproj -scheme VirtualAndroid \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=<device>' \
  -derivedDataPath app/build/DerivedData build
xcrun simctl install <udid> app/build/DerivedData/Build/Products/Debug-iphonesimulator/VirtualAndroid.app
xcrun simctl launch <udid> dev.virtualandroid.app -VAEngine stub
app/scripts/run_pure_tests.sh              # bootconfig == tools/make_initrd.py, geometry, argv, keymap
```

Device: set `DEVELOPMENT_TEAM` in project.yml. The entitlements
`com.apple.developer.kernel.increased-memory-limit` and
`...extended-virtual-addressing` need a **paid** team; Debug adds
`get-task-allow` (debugger attach = JIT via CS_DEBUGGED, e.g. Xcode/StikDebug).
`-sdk iphoneos CODE_SIGNING_ALLOWED=NO` checks that it compiles without a team.

## Engines

`Engine/Engine.swift` defines `VMEngine` (lifecycle) + `EngineInput`
(the va_engine_* calls). Two implementations:

* `StubEngine`: 60 Hz animated test pattern rendered into a ring of BGRA
  IOSurfaces, simulated 5 s boot (BOOTING -> BOOT_COMPLETED), touch/key echo,
  auto-rotation from the accelerometer it enables, and "simulate guest
  request" toggles (Diagnostics sheet) that drive every `VaHostCallbacks`
  entry through the same C ABI the real engine uses.
* `QemuEngine`: dlopens `Frameworks/qemu-aarch64-softmmu.framework`, resolves
  `qemu_init(argc, argv)` / `int qemu_main_loop()` / `qemu_cleanup(int)` (QEMU 10
  signatures) and the `va_*` symbols, calls `va_host_set_callbacks()` and
  `va_host_set_present_callback()` before `qemu_init`, runs QEMU on an
  8 MB-stack pthread with UTM's exit() interception (`Support/VAEngineRuntime.m`),
  and controls it over QMP on a socketpair (`-chardev socket,fd=N`).
  ranchu dlopens libva_gfx (`-M ranchu,gfx-lib=<bundle>/Frameworks/va_gfx.framework/va_gfx`;
  its default lookup is the same path) and calls the present callback on a
  renderer thread with zero-copy BGRA IOSurfaces (row 0 = top), which the
  Metal view retains until the next frame.

Selection (`Automatic`): QEMU when the framework is embedded and an image is
installed, else the stub. `scripts/embed_engine_frameworks.sh` (build phase)
embeds every xcframework from `engine/build-ios/xcframeworks` and
`gfx/build-ios-xcframeworks` (slice for the SDK) and writes
`VAEngineBackend.txt` (`tcg` = JIT, `tcti`) from `qemu-backends.txt`; the app
uses `-accel tcg,thread=multi,tb-size=1024` (simulator), `...,tb-size=512,split-wx=on`
(device + JIT) or `...,tb-size=512` (TCTI). A JIT build is refused when the
process cannot JIT. `VA_STUB_ONLY=1` skips embedding. QEMU can run once per
process (globals); a second boot asks to relaunch.

## Image pack and storage

An image pack is a folder with:
`kernel-ranchu ramdisk.img system.img vendor.img encryptionkey.(qcow2|img)
userdata.qcow2 cache.qcow2 [manifest.json]`. iOS has no mke2fs, so the empty
ext4 disks are made on the Mac:

```sh
app/scripts/make_userdata_qcow2.sh --pack      # -> app/build/ImagePack (APFS clones, ~10 MB real)
```

Side-load into the simulator (clones, no extra space on the same volume):

```sh
DATA=$(xcrun simctl get_app_container <udid> dev.virtualandroid.app data)
mkdir -p "$DATA/Documents/ImagePack" && cp -c app/build/ImagePack/* "$DATA/Documents/ImagePack/"
```

On a device copy the folder as `ImagePack` into the app's Documents (Finder
file sharing / Files app), or use "Import image pack folder…". On first launch
the pack is installed automatically (copyfile `COPYFILE_CLONE`) into
`Library/Application Support/VirtualAndroid/images/android-33-arm64-v8a/`; the
writable disks + initrd + logs live in `.../vms/default/` (excluded from backup).
"Reset Android data" deletes `vms/default` (fresh userdata from the template).

The initrd is the ramdisk + bootconfig (`VM/BootConfig.swift`, byte-identical
port of `tools/make_initrd.py`), with `androidboot.opengles.version` from
`va_gfx_get_gles_version()` (cached from the previous run; 196608 = GLES 3.0
for ANGLE Metal otherwise). QEMU argv (`VM/QemuArguments.swift`) mirrors
`tools/run-macos.sh --machine ranchu`: `-M ranchu,gfx-lib=...` (override
`-VAMachine virt`), cortex-a76, 4 vCPU, 2 GB, disks vendor/encrypt/userdata/
cache/system in that order (writable ones qcow2), virtio net
(no slirp adb forward on ranchu), rng, virtio-serial hvc0/hvc1 (logcat) into
files, `-device va-vsock-pci,guest-cid=77,adb-port=<port>,pipe-port=5000`
(adbd and the clipboard service talk vsock), QMP. adb: port 5570 on the
simulator (it shares the Mac's loopback: `adb connect 127.0.0.1:5570`),
off on devices unless `-VAAdbPort N`. Bootconfig: `opengles.version=196608`
(ANGLE Metal GLES 3.0), `camera_protocol_ver=0`, and for dev builds
`androidboot.qemu.adb.pubkey` from `adbkey.pub` (Documents/adbkey.pub, else the
image pack's copy, which `make_userdata_qcow2.sh --pack` takes from
`~/.android/adbkey.pub`; `VA_NO_ADBKEY=1` for packs you give away).

## M4 fast resume (snapshots; docs/SNAPSHOT.md)

Files: `VM/Snapshot.swift` (pure: manifest, validity, launch plan, lifecycle
state machine, QMP sequences, hashing; unit-tested), `VM/SnapshotManager.swift`
(files), `Display/FrameImage.swift` (last-frame.png), engine `suspend()` /
restore in `Engine/QemuEngine.swift` and `Engine/StubEngine.swift`.

* Snapshot mode argv: `-object memory-backend-file,id=ram0,size=2048M,mem-path=<vm>/snapshot/ram.img,share=on`,
  `-M ranchu,...,snapshot-dir=<vm>/snapshot,memory-backend=ram0`; restore adds
  `-S -incoming defer`. Enabled when "Fast resume" is on and the embedded QEMU
  has the ranchu `snapshot-dir` property (probed in the binary;
  `-VASnapshotSupport YES|NO` overrides).
* Background (`beginBackgroundTask`): QMP `stop` -> `migrate-set-parameters
  mode=cpr-reboot` -> `migrate-set-capabilities x-ignore-shared` -> `migrate`
  (file channel `state.tmp`) -> poll `query-migrate` until completed
  (postmigrate) -> rename to `state.bin` -> `last-frame.png` -> `manifest.json`
  `{version, engine, gfx, image, argv_hash, clean: true, saved_at}`. QEMU stays
  alive. Host events (touch, keys, sensors, GNSS, battery, clipboard) are not
  forwarded while the guest is stopped, so the saved RAM/state cannot change.
* Foreground with QEMU alive: manifest `clean=false`, then `cont` (instant).
* Cold launch with a valid manifest (clean, same engine/gfx/image/argv hash,
  state.bin and 2 GB ram.img and disks present): show `last-frame.png` under a
  "Restoring…" overlay, start QEMU with `-S -incoming defer`, same
  parameter/capability, `migrate-incoming` (`exit-on-error=false`), poll, then
  `clean=false` and `cont`. Anything invalid -> discard snapshot (incl. ram.img)
  and cold boot. A failed load cannot fall back in-process (QEMU runs once per
  process): the snapshot is discarded and the app asks to be relaunched.
* **Snapshots are taken only when leaving the app**, never "right after the
  first boot, then keep running": RAM (ram.img) and disks change in place as
  soon as the guest runs, so such a snapshot would be inconsistent by the time
  it is used. The manifest is clean only between a suspend and the next
  `cont`; a kill while running means a cold boot (like pulling the power).
* Hashes: engine = SHA-256 of the QEMU binary, gfx = va_gfx + GLESv2, image =
  name/size/mtime of kernel/ramdisk/system/vendor + pack manifest + bootconfig,
  argv = machine-defining argv with container/bundle paths normalized and the
  QMP fd/-S/-incoming removed (binary hashes are cached by size+mtime).
* Settings: "Fast resume" toggle, snapshot info, "Discard snapshot / cold boot
  next time"; VM menu: "Cold boot (discard snapshot)".
* `app/scripts/m4_e2e.sh [--stub] [--rounds N]`: launch -> interactive,
  background -> suspend, `simctl terminate`, relaunch -> times (log lines
  `restore: last frame shown / state loaded / guest running / first live frame +N ms`
  since process start; QEMU: adb focus on Launcher3).

Measured 2026-11-04 (simulator): stub: suspend 0.1 s, relaunch -> live 0.6 s.
Real QEMU with `-M virt` (no graphics; `-VAMachine virt -VASnapshotSupport YES`):
suspend `migrate` 50-73 ms (state.bin 441 KB, ram.img 1.3 GB allocated),
relaunch -> state loaded in 158 ms, guest running +750 ms after process start,
kernel log continues where it stopped; background -> foreground `cont` after
postmigrate works. ranchu + gfx pending (board/gfx snapshot halves).

## Display, rotation, input

* `Display/MetalDisplayView.swift`: CAMetalLayer, frames drawn on a CADisplayLink,
  letterboxed at the frame's aspect (1080x2340). IOSurface textures are wrapped
  per draw and never cached (libva_gfx recycles only surfaces nobody holds).
* Rotation: default "panel fixed to device": the guest panel stays fixed to the
  hardware like a real phone; the frame is counter-rotated for the interface
  orientation and `va_engine_set_display_rotation()` gets the Android surface
  rotation (device turned CCW: interface landscapeRight = 90, landscapeLeft = 270).
  `VaGfxFrame.rotation_deg` is added as an extra clockwise rotation.
  "Always upright" mode draws the frame unrotated.
* Touch: up to 10 fingers, stable slots 0..9, coordinates 0..1 in guest panel
  space (inverse of the drawing rotation); lifted slots then all down slots are
  sent per event. Touches starting in the letterbox bars are ignored.
* Keyboard: UIKey HID usage -> Linux keycode (kernel hid_keyboard table).
* On-screen controls (trailing-edge handle): back 158, home 172, recents 580
  (KEY_APPSELECT), power 116, volume 115/114 (down on press, up on release), and
  a VM menu (pause/resume, paste, hold power, rotation, snapshot, shutdown).

## Platform bridges (Bridges/)

| Guest | iOS | Notes |
|---|---|---|
| accelerometer | CMAccelerometer | iOS g with gravity negative (upright y = -1 g) -> Android m/s² specific force (upright y = +9.81): **android = -ios × 9.80665**. Same axes (x right, y up, z out of screen). |
| gravity / linear accel | CMDeviceMotion.gravity / userAcceleration | same negation and scale |
| gyroscope | CMDeviceMotion.rotationRate (raw gyro fallback) | rad/s, same right-hand axes, unchanged |
| magnetic field | CMDeviceMotion.magneticField (calibrated), raw magnetometer fallback | µT, unchanged |
| rotation vector | attitude quaternion, frame X=magnetic north Z=up | q_android = q_z(+90°) · q_ios (NWU -> ENU), convention checked against gravity; w ≥ 0 |
| orientation (legacy) | from the rotation matrix | like SensorManager.getOrientation, degrees |
| pressure | CMAltimeter | kPa × 10 = hPa |
| simulator | — | accel/gravity synthesized from the display rotation |
| GNSS | CLLocationManager | when-in-use authorization requested on location_set_enabled(true) |
| battery | UIDevice battery + thermalState | voltage nominal, temperature approximated; unknown (simulator) -> engine default |
| clipboard | UIPasteboard | guest->iOS always; iOS->guest on "Paste" (or auto on activate if enabled) to avoid the paste prompt |
| camera | AVCaptureSession 420f -> VTPixelTransferSession -> NV21 | back 90°, front 270°; synthetic camera when none (simulator) |
| speaker / mic | AVAudioEngine + lock-free PCM16 rings (`Support/VARingBuffer.c`) | mic permission on mic_start; session .playback, .playAndRecord only while a real mic captures. **Simulator**: real input needs the Mac's microphone permission for Simulator, otherwise CoreAudio aborts the app ("Initialize: RPC timeout. Apparently deadlocked"), so the simulator uses a synthetic 300 Hz mic unless `-VASimulatorMic YES` |
| vibrator | CoreHaptics continuous event | |

Sensor timestamps are host CLOCK_UPTIME_RAW ns (CoreMotion's time base).

## Real boot in the simulator (measured 2026-11-04, iPhone 17 Pro sim, TCG JIT, M2 Max under load)

| run | BOOT_COMPLETED (from VM start) | launcher focused (from app launch) |
|---|---|---|
| first launch (image install + fresh userdata) | 170.6 s | ~187 s |
| later launches (warm userdata) | 70.2 s / 79.4 s | ≤ 97 s (first check) |

End-to-end UI test (`Tests/UI/RealBootUITests.swift`, real UIKit taps on the
Metal view and the overlay; TEST EXECUTE SUCCEEDED): tap Gallery -> adb focus
`com.android.gallery3d/.app.GalleryActivity`; overlay HOME -> Launcher3;
tap Phone -> `com.android.dialer/.main.impl.MainActivity`; overlay BACK ->
Launcher3; menu "Force stop" -> QMP quit, `qemu_cleanup`, app stays alive.

```sh
xcodebuild ... build-for-testing
xcodebuild -project app/VirtualAndroid.xcodeproj -scheme VirtualAndroid \
  -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath app/build/DerivedData \
  test-without-building -only-testing:VirtualAndroidUITests   # needs the image pack installed
```

Screenshots: `docs/screenshot-real-boot.png`, `docs/screenshot-real-home.png`,
`docs/screenshot-real-gallery-after-tap.png`.

## Developer launch arguments

`-VAEngine stub|qemu|auto`, `-VAAutoBoot YES|NO`, `-VAMachine virt`,
`-VAAutoStopAfter <s>` (QMP quit), `-VANavExpanded YES`,
`-VAForceOrientation landscapeLeft|landscapeRight|portrait`,
`-VASelfTest YES` (injects two touches + VOL+/BACK after boot),
`-VAStubDiagnostics gnss,camera,mic,tone,sensors,vibrate,copy` (stub: simulate
guest requests after boot and log every bridge's status 6 s later),
`-VASimulatorMic YES`, `-VASnapshotSupport YES|NO`, `-VAFastResume NO`, `-VAAdbPort N`, `-VATrace event,...`, `-VADumpFrames YES`
(libva_gfx PNG dumps in vms/default/frames), `-VAScript "wait:5;tap:0.31,0.74;key:172"`
(after boot: guest-coordinate taps through the view mapping, keys). Pre-grant simulator permissions with
`xcrun simctl privacy <udid> grant location|camera|microphone|motion dev.virtualandroid.app`
and set a position with `xcrun simctl location <udid> set <lat>,<lon>`.
Guest logs: `vms/default/{serial,logcat,hvc0}.log` in the app container.
