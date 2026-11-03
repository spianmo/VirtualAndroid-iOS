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
  signatures) and the `va_*` symbols, installs the callbacks, runs QEMU on an
  8 MB-stack pthread with UTM's exit() interception (`Support/VAEngineRuntime.m`),
  and controls it over QMP on a socketpair (`-chardev socket,fd=N`).

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
`tools/run-macos.sh`: `-M ranchu` (override `-VAMachine virt`), cortex-a76,
4 vCPU, 2 GB, disks vendor/encrypt/userdata/cache/system in that order
(writable ones qcow2 so `savevm` works), virtio net (+adb 127.0.0.1:5555 on the
simulator), rng, virtio-serial hvc0/hvc1 (logcat) into files, QMP.

Snapshot placeholder (M4, `VM/SnapshotStore.swift`): "Quick boot" saves
`savevm va-quickboot` after the first boot and boots with `-loadvm` when the
image/config fingerprint matches. Needs vmstate for the goldfish devices and
gfx pipes before it can work with QEMU; the stub simulates it.

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
| speaker / mic | AVAudioEngine + lock-free PCM16 rings (`Support/VARingBuffer.c`) | mic permission on mic_start; session .playback / .playAndRecord, mixWithOthers |
| vibrator | CoreHaptics continuous event | |

Sensor timestamps are host CLOCK_UPTIME_RAW ns (CoreMotion's time base).

## Developer launch arguments

`-VAEngine stub|qemu|auto`, `-VAAutoBoot YES|NO`, `-VAMachine virt`,
`-VAAutoStopAfter <s>` (QMP quit), `-VANavExpanded YES`,
`-VAForceOrientation landscapeLeft|landscapeRight|portrait`,
`-VASelfTest YES` (injects two touches + VOL+/BACK after boot).
Guest logs: `vms/default/{serial,logcat,hvc0}.log` in the app container.
