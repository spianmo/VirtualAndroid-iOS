// Host-side checks for the platform-independent app logic. Run with
// app/scripts/run_pure_tests.sh (compiles with swiftc on macOS).
import CoreGraphics
import Foundation

var failures = 0
var checks = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond() { failures += 1; print("FAIL (line \(line)): \(msg)") }
}

// MARK: BootConfig == tools/make_initrd.py
let args = CommandLine.arguments
if args.count >= 3 {
    let ramdisk = URL(fileURLWithPath: args[1])
    let python = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("va-initrd-swift")
    try BootConfig.buildInitrd(ramdisk: ramdisk, output: out, overrides: ["androidboot.qemu.skin": "1080x2340"])
    let swift = try Data(contentsOf: out)
    check(swift == python, "initrd differs from make_initrd.py (\(swift.count) vs \(python.count) bytes)")
    check(String(decoding: swift.suffix(12), as: UTF8.self) == "#BOOTCONFIG\n", "trailer magic")
    check(swift.range(of: Data("androidboot.logcat=\"*:I\"\n".utf8)) != nil, "logcat at info level")
    check(swift.range(of: Data("ro.hw_timeout_multiplier=5\n".utf8)) != nil, "debug prop (literal lz4 block)")
    check(swift.range(of: Data("dalvik.vm.usejit".utf8)) == nil, "the JIT stays on")
    let bt = "ro.bluetooth.ble_start_timeout_delay=20000\nro.bluetooth.ble_stop_timeout_delay=20000\n"
    check(swift.range(of: Data(bt.utf8)) != nil, "Bluetooth BLE step timeouts")
    check(swift.range(of: Data("bluetooth.framework.support_persisted_state=false\n".utf8)) != nil,
          "no Bluetooth auto-enable at boot (the engine enables it)")
    check(swift.range(of: Data("bluetooth.profile.a2dp".utf8)) == nil, "A2DP keeps the image's setting")
    if args.count >= 4 {
        // make_initrd.py --prebaked
        let pythonPrebaked = try Data(contentsOf: URL(fileURLWithPath: args[3]))
        try BootConfig.buildInitrd(ramdisk: ramdisk, output: out, overrides: ["androidboot.qemu.skin": "1080x2340"],
                                   prebaked: true)
        let prebaked = try Data(contentsOf: out)
        check(prebaked == pythonPrebaked, "prebaked initrd differs from make_initrd.py --prebaked " +
                                          "(\(prebaked.count) vs \(pythonPrebaked.count) bytes)")
        let props = "bluetooth.profile.pbap.server.enabled=false\n" +
                    "ro.bluetooth.ble_start_timeout_delay=20000\nro.bluetooth.ble_stop_timeout_delay=20000\n" +
                    "ro.hw_timeout_multiplier=5\n"
        check(prebaked.range(of: Data(props.utf8)) != nil, "prebaked adb_debug.prop")
        check(prebaked.range(of: Data("dalvik.vm.usejit".utf8)) == nil, "prebaked: the JIT stays on")
        check(prebaked.range(of: Data("pm.dexopt".utf8)) == nil, "prebaked: the image's dexopt filters")
    }
    try? FileManager.default.removeItem(at: out)
}
check(BootConfig.debugProperties(prebaked: false) == BootConfig.debugProps, "default debug props")
check(BootConfig.debugProperties(prebaked: true) == BootConfig.debugProps, "prebaked: no extra props")

// MARK: DisplayGeometry: corner UVs and touch mapping are inverse of each other.
for k in 0..<4 {
    let uvs = DisplayGeometry.cornerUVs(quarterTurns: k)          // BL, BR, TL, TR
    let screen: [(CGFloat, CGFloat)] = [(0, 1), (1, 1), (0, 0), (1, 0)]
    for (i, s) in screen.enumerated() {
        let g = DisplayGeometry.guestPoint(u: s.0, v: s.1, quarterTurns: k)
        check(Float(g.x) == uvs[i].x && Float(g.y) == uvs[i].y, "k=\(k) corner \(i): touch \(g) vs uv \(uvs[i])")
    }
}
let portrait = DisplayGeometry.letterbox(content: CGSize(width: 1080, height: 2340),
                                         in: CGSize(width: 402, height: 874), quarterTurns: 0)
check(abs(portrait.width / portrait.height - 1080.0 / 2340.0) < 0.001, "portrait aspect")
let landscape = DisplayGeometry.letterbox(content: CGSize(width: 1080, height: 2340),
                                          in: CGSize(width: 874, height: 402), quarterTurns: 1)
check(abs(landscape.width / landscape.height - 2340.0 / 1080.0) < 0.001, "landscape aspect")
check(abs(landscape.midX - 437) < 0.001 && abs(landscape.midY - 201) < 0.001, "landscape centered")

// MARK: argv matches tools/run-macos.sh layout.
let root = URL(fileURLWithPath: "/img")
func disk(_ n: String, _ f: String, _ ro: Bool) -> DiskImage { DiskImage(url: root.appendingPathComponent(n), format: f, readOnly: ro) }
var b = QemuArgumentBuilder(kernel: root.appendingPathComponent("kernel-ranchu"), initrd: root.appendingPathComponent("initrd"),
                            vendor: disk("vendor.img", "raw", true), encryption: disk("encryptionkey.qcow2", "qcow2", false),
                            userdata: disk("userdata.qcow2", "qcow2", false), cache: disk("cache.qcow2", "qcow2", false),
                            system: disk("system.img", "raw", true),
                            serialLog: root.appendingPathComponent("serial.log"), hvc0Log: root.appendingPathComponent("hvc0.log"),
                            logcatLog: root.appendingPathComponent("logcat.log"))
b.qmpFD = 7
b.adbHostPort = 5555
let argv = b.build()
let drives = argv.enumerated().filter { $0.element == "-drive" }.map { argv[$0.offset + 1] }
check(drives.map { $0.components(separatedBy: ",")[1] } == ["id=vendor", "id=encrypt", "id=userdata", "id=cache", "id=system"], "disk order")
check(drives[0].hasSuffix("format=raw,read-only=on") && drives[2].contains("format=qcow2"), "disk formats")
check(argv.contains("socket,id=qmp0,fd=7") && argv.contains("chardev=qmp0,mode=control"), "qmp chardev")
// ranchu (default): adb over va-vsock-pci, no slirp forward; like run-macos.sh --machine ranchu.
check(argv.contains("user,id=mynet"), "no hostfwd on ranchu")
check(argv.contains("va-vsock-pci,guest-cid=77,adb-port=5555,pipe-port=5000"), "vsock adb")
check(argv.contains("va-wifi-pci,netdev=wifi0") && argv.contains("user,id=wifi0,dhcpstart=10.0.2.16"), "wifi ap")
check(argv.contains("va-bluetooth"), "bluetooth controller")
check(argv.contains("virtio-sound-pci,audiodev=snd0") && argv.contains { $0.hasPrefix("va,id=snd0,") }, "sound card on the va backend")
check(argv.contains("chardev:vaconsole") && argv.contains { $0.hasPrefix("ringbuf,id=vaconsole,") }, "engine console")
check(argv[argv.firstIndex(of: "-M")! + 1] == "ranchu", "machine ranchu (bundle gfx lookup)")
var bv = b
bv.machine = "virt"
let argvVirt = bv.build()
check(argvVirt.contains("user,id=mynet,hostfwd=tcp:127.0.0.1:5555-:5555") && !argvVirt.contains("-device") == false, "virt hostfwd")
check(!argvVirt.joined(separator: " ").contains("va-vsock-pci"), "no vsock on virt")
check(!argvVirt.contains("va-bluetooth") && !argvVirt.contains("va-wifi-pci,netdev=wifi0"), "no wifi/bt on virt")
b.gfxLib = "/a,b/va_gfx"
check(b.build().contains("ranchu,gfx-lib=/a,,b/va_gfx"), "gfx-lib escaped")
b.graphics = false
check(b.build().contains("ranchu,gfx=off"), "gfx off")
b.graphics = true
b.gfxLib = nil
b.ramFile = "/S/snap/ram.img"
b.snapshotDir = "/S/snap"
b.incomingDefer = true
let snapArgv = b.build()
check(snapArgv[snapArgv.firstIndex(of: "-M")! + 1] == "ranchu,snapshot-dir=/S/snap,memory-backend=ram0", "snapshot machine props: \(snapArgv[snapArgv.firstIndex(of: "-M")! + 1])")
check(snapArgv.contains("memory-backend-file,id=ram0,size=2048M,mem-path=/S/snap/ram.img,share=on"), "file-backed RAM")
check(snapArgv.suffix(3) == ["-S", "-incoming", "defer"] || snapArgv.contains("defer"), "incoming defer")
b.incomingDefer = false
check(SnapshotHash.argvHash(snapArgv, replacing: []) == SnapshotHash.argvHash(b.build(), replacing: []), "restore argv hashes like the cold-boot argv")
check(QemuArgumentBuilder.escape("/a,b") == "/a,,b", "comma escape")
// Kernel command line (as tools/run-macos.sh; -VAKernelPerf NO / VA_KERNEL_PERF=0 drop the perf words).
let cmdline = argv[argv.firstIndex(of: "-append")! + 1]
check(QemuArgumentBuilder.kernelPerfArguments == "kpti=0 nokaslr mitigations=off init_on_alloc=0", "kernel perf args")
check(cmdline == QemuArgumentBuilder.kernelCommandLine + " kpti=0 nokaslr mitigations=off init_on_alloc=0",
      "kernel cmdline: \(cmdline)")
check(cmdline.hasPrefix("8250.nr_uarts=1 no_timer_check console=ttyAMA0,38400 keep_bootcon earlyprintk=ttyAMA0 ") &&
      cmdline.contains(" loop.max_loop=64 ") && cmdline.contains(" bootconfig"), "kernel cmdline base")
var bp = b
bp.kernelPerf = false
let plain = bp.build()
check(plain[plain.firstIndex(of: "-append")! + 1] == QemuArgumentBuilder.kernelCommandLine, "kernel perf args off")
check(argv[argv.firstIndex(of: "-smp")! + 1] == "4", "4 vCPUs by default")
bp.cpuCount = 2
let smp2 = bp.build()
check(smp2[smp2.firstIndex(of: "-smp")! + 1] == "2", "-VACPUCount")
check(AccelMode.tcti.qemuValue == "tcg,thread=multi,tb-size=512", "tcti accel")
check(AccelMode.tcti.qemuValue(tbSizeMB: 1536) == "tcg,thread=multi,tb-size=1536", "tcti tb-size")
check(AccelMode.tctiTBSizeMB(availableMB: 3000, guestMB: 2048) == 512, "tcti tb-size floor")
check(AccelMode.tctiTBSizeMB(availableMB: 5000, guestMB: 2048) == 1280, "tcti tb-size from available memory")
check(AccelMode.tctiTBSizeMB(availableMB: 9000, guestMB: 2048) == 2048, "tcti tb-size cap")
var btb = b
btb.accel = .tcti
btb.tbSizeMB = 1792
let tbArgv = btb.build()
check(tbArgv[tbArgv.firstIndex(of: "-accel")! + 1] == "tcg,thread=multi,tb-size=1792", "builder tb-size")

// MARK: Keymap spot checks (HID usage -> Linux).
check(LinuxKeymap.keycode(forHIDUsage: 0x04) == 30, "A")
check(LinuxKeymap.keycode(forHIDUsage: 0x28) == 28, "Enter")
check(LinuxKeymap.keycode(forHIDUsage: 0x29) == 1, "Esc")
check(LinuxKeymap.keycode(forHIDUsage: 0x4F) == 106, "Right")
check(LinuxKeymap.keycode(forHIDUsage: 0x52) == 103, "Up")
check(LinuxKeymap.keycode(forHIDUsage: 0xE3) == 125, "Left GUI")
check(LinuxKeymap.keycode(forHIDUsage: 0x80) == 115, "Volume up")


// MARK: Snapshot manifest / validity / launch plan / lifecycle (M4)
do {
    let id = SnapshotIdentity(engine: "e1", gfx: "g1", image: "i1", argvHash: "a1")
    var m = SnapshotManifest(version: SnapshotManifest.currentVersion, engine: "e1", gfx: "g1", image: "i1",
                             argvHash: "a1", clean: true, savedAt: Date(timeIntervalSince1970: 1_800_000_000),
                             guestBootCompleted: true, appVersion: "0.1.0", suspendMillis: 230)
    // JSON field names per docs/SNAPSHOT.md, round trip.
    let json = String(decoding: try m.encoded(), as: UTF8.self)
    for key in ["\"version\"", "\"engine\"", "\"gfx\"", "\"image\"", "\"argv_hash\"", "\"clean\"", "\"saved_at\""] {
        check(json.contains(key), "manifest key \(key)")
    }
    check(json.contains("2027-01-15T08:00:00Z"), "saved_at ISO8601: \(json)")
    check(SnapshotManifest.decode(Data(json.utf8)) == m, "manifest round trip")
    check(SnapshotManifest.decode(Data("{\"version\":1}".utf8)) == nil, "incomplete manifest rejected")

    let files = SnapshotFiles(stateBinBytes: 94 << 20, ramImgBytes: 2 << 30, expectedRamBytes: 2 << 30, hasLastFrame: true)
    check(SnapshotValidator.validate(manifest: m, identity: id, files: files) == .valid, "valid snapshot")
    check(SnapshotValidator.validate(manifest: nil, identity: id, files: files) != .valid, "no manifest")
    var dirty = m; dirty.clean = false
    check(SnapshotValidator.validate(manifest: dirty, identity: id, files: files) != .valid, "dirty invalid")
    for (k, v) in [("engine", "e2"), ("gfx", "g2"), ("image", "i2"), ("argv", "a2")] {
        var other = id
        switch k {
        case "engine": other.engine = v
        case "gfx": other.gfx = v
        case "image": other.image = v
        default: other.argvHash = v
        }
        check(SnapshotValidator.validate(manifest: m, identity: other, files: files) != .valid, "\(k) mismatch invalid")
    }
    var noState = files; noState.stateBinBytes = 0
    check(SnapshotValidator.validate(manifest: m, identity: id, files: noState) != .valid, "missing state.bin")
    var badRam = files; badRam.ramImgBytes = 1 << 30
    check(SnapshotValidator.validate(manifest: m, identity: id, files: badRam) != .valid, "ram size mismatch")
    var noDisks = files; noDisks.disksPresent = false
    check(SnapshotValidator.validate(manifest: m, identity: id, files: noDisks) != .valid, "disks missing")
    var oldVersion = m; oldVersion.version = 0
    check(SnapshotValidator.validate(manifest: oldVersion, identity: id, files: files) != .valid, "version mismatch")
    m.clean = true

    // Launch plan.
    check(LaunchPlan.decide(snapshotsEnabled: true, engineSupportsSnapshots: true, manifest: m, validity: .valid) == .restore, "plan restore")
    if case .coldBoot(let discard, _) = LaunchPlan.decide(snapshotsEnabled: true, engineSupportsSnapshots: true, manifest: dirty, validity: .invalid("x")) {
        check(discard, "dirty snapshot discarded")
    } else { check(false, "dirty -> cold boot") }
    if case .coldBoot(let discard, _) = LaunchPlan.decide(snapshotsEnabled: true, engineSupportsSnapshots: true, manifest: nil, validity: .invalid("none")) {
        check(!discard, "nothing to discard")
    } else { check(false, "none -> cold boot") }
    if case .coldBoot = LaunchPlan.decide(snapshotsEnabled: false, engineSupportsSnapshots: true, manifest: m, validity: .valid) {} else { check(false, "disabled -> cold boot") }
    if case .coldBoot = LaunchPlan.decide(snapshotsEnabled: true, engineSupportsSnapshots: false, manifest: m, validity: .valid) {} else { check(false, "unsupported -> cold boot") }

    // Lifecycle: invariant "never cont on a clean snapshot without markDirty first".
    func assertInvariant(_ actions: [VMLifecycle.Action], cleanBefore: Bool, _ msg: String) {
        if let c = actions.firstIndex(of: .cont), cleanBefore {
            check(actions.firstIndex(of: .markDirty).map { $0 < c } ?? false, "markDirty before cont: \(msg) \(actions)")
        }
    }
    typealias A = VMLifecycle.Action
    // 1. Cold boot, background, foreground (process alive).
    var lc = VMLifecycle()
    check(lc.handle(.launch(.coldBoot(discard: true, reason: "x"))) == [.discardSnapshot, .startColdBoot], "cold boot actions")
    check(lc.handle(.bootCompleted) == [], "no snapshot after first boot (by design)")
    check(lc.state == .running, "running after boot")
    check(lc.handle(.enterBackground(canSnapshot: true, keepRunning: false)) == [.pause, .suspend], "suspend on background")
    check(lc.state == .suspending, "suspending")
    check(lc.handle(.suspendSaved) == [.finalizeSnapshot], "finalize")
    check(lc.state == .suspended && lc.snapshotClean, "suspended clean")
    var acts = lc.handle(.enterForeground)
    check(acts == [.markDirty, .cont], "foreground: markDirty then cont, got \(acts)")
    check(lc.state == .running && !lc.snapshotClean, "running dirty")

    // 2. Restore path (cold launch with a valid snapshot).
    lc = VMLifecycle()
    check(lc.handle(.launch(.restore)) == [.showLastFrame, .startRestore], "restore actions")
    check(lc.state == .restoring, "restoring")
    acts = lc.handle(.restoreLoaded)
    assertInvariant(acts, cleanBefore: true, "restore")
    check(acts == [.markDirty, .cont], "restore -> markDirty, cont")
    check(lc.state == .running, "running after restore")

    // 3. Restore failure -> discard + relaunch needed.
    lc = VMLifecycle()
    lc.handle(.launch(.restore))
    acts = lc.handle(.restoreFailed("bad state"))
    check(acts.first == .discardSnapshot && acts.contains(where: { if case .requireRelaunch = $0 { return true }; return false }), "restore failure actions \(acts)")
    if case .failed = lc.state {} else { check(false, "failed state") }

    // 4. Background while restoring: loaded but not run -> stays clean, suspended.
    lc = VMLifecycle()
    lc.handle(.launch(.restore))
    lc.handle(.enterBackground(canSnapshot: true, keepRunning: false))
    check(lc.handle(.restoreLoaded) == [], "loaded in background: do not run")
    check(lc.state == .suspended && lc.snapshotClean, "still clean")
    check(lc.handle(.enterForeground) == [.markDirty, .cont], "then foreground runs")

    // 5. Foreground while the suspend is still writing.
    lc = VMLifecycle()
    lc.handle(.launch(.coldBoot(discard: false, reason: "")))
    lc.handle(.bootCompleted)
    lc.handle(.enterBackground(canSnapshot: true, keepRunning: false))
    check(lc.handle(.enterForeground) == [], "foreground during suspend waits")
    acts = lc.handle(.suspendSaved)
    check(acts == [.finalizeSnapshot, .markDirty, .cont], "finish suspend then resume: \(acts)")
    check(lc.state == .running && !lc.snapshotClean, "running after late resume")

    // 6. Suspend fails -> discard; foreground -> plain cont.
    lc = VMLifecycle()
    lc.handle(.launch(.coldBoot(discard: false, reason: "")))
    lc.handle(.enterBackground(canSnapshot: true, keepRunning: false))
    check(lc.handle(.suspendFailed("io")) == [.discardSnapshot], "suspend failure discards")
    check(lc.state == .pausedInBackground, "paused without snapshot")
    check(lc.handle(.enterForeground) == [.cont], "plain cont")

    // 7. Snapshots off: pause/cont; keepRunning: nothing.
    lc = VMLifecycle()
    lc.handle(.launch(.coldBoot(discard: false, reason: "")))
    check(lc.handle(.enterBackground(canSnapshot: false, keepRunning: false)) == [.pause], "pause only")
    check(lc.handle(.enterForeground) == [.cont], "cont")
    check(lc.handle(.enterBackground(canSnapshot: true, keepRunning: true)) == [], "keep running in background")
    check(lc.state == .running, "still running")

    // 8. User paused, then background/foreground: stays paused, snapshot clean until resume.
    lc = VMLifecycle()
    lc.handle(.launch(.coldBoot(discard: false, reason: "")))
    lc.handle(.bootCompleted)
    check(lc.handle(.userPause) == [.pause], "user pause")
    check(lc.handle(.enterBackground(canSnapshot: true, keepRunning: false)) == [.suspend], "already stopped: suspend only")
    lc.handle(.suspendSaved)
    check(lc.handle(.enterForeground) == [], "stays paused")
    check(lc.state == .userPaused && lc.snapshotClean, "user paused, clean")
    check(lc.handle(.userResume) == [.markDirty, .cont], "user resume marks dirty")

    // 9. Discard while idle; engine stop.
    lc = VMLifecycle()
    check(lc.handle(.discardSnapshot) == [.discardSnapshot], "discard idle")
    lc.handle(.launch(.restore))
    lc.handle(.restoreLoaded)
    lc.handle(.engineStopped)
    check(lc.state == .stopped, "stopped")

    // 10. Exhaustive-ish: random event sequences never cont on a clean snapshot.
    var rng = SystemRandomNumberGenerator()
    let events: [VMLifecycle.Event] = [.bootCompleted, .restoreLoaded, .enterBackground(canSnapshot: true, keepRunning: false),
                                       .enterBackground(canSnapshot: false, keepRunning: false), .suspendSaved,
                                       .suspendFailed("x"), .enterForeground, .userPause, .userResume, .discardSnapshot]
    for _ in 0..<2000 {
        var l = VMLifecycle()
        l.handle(.launch(Bool.random(using: &rng) ? .restore : .coldBoot(discard: true, reason: "")))
        for _ in 0..<20 {
            let clean = l.snapshotClean
            let a = l.handle(events.randomElement(using: &rng)!)
            assertInvariant(a, cleanBefore: clean, "random")
            if a.contains(.cont) { check(!l.snapshotClean, "clean after cont") }
        }
    }

    // QMP protocol sequence (docs/SNAPSHOT.md).
    let sus = SnapshotProtocol.suspend(stateTmp: "/a b/state.tmp")
    check(sus.map(\.execute) == ["stop", "migrate-set-parameters", "migrate-set-capabilities", "migrate"], "suspend sequence")
    check((sus[1].jsonArguments?["mode"] as? String) == "cpr-reboot", "cpr-reboot")
    let caps = sus[2].jsonArguments?["capabilities"] as? [[String: Any]]
    check(caps?.first?["capability"] as? String == "x-ignore-shared" && caps?.first?["state"] as? Bool == true, "x-ignore-shared")
    let ch = (sus[3].jsonArguments?["channels"] as? [[String: Any]])?.first
    let addr = ch?["addr"] as? [String: Any]
    check(ch?["channel-type"] as? String == "main" && addr?["transport"] as? String == "file" && addr?["filename"] as? String == "/a b/state.tmp", "file channel")
    check(JSONSerialization.isValidJSONObject(sus[3].jsonArguments!), "json-serializable")
    let res = SnapshotProtocol.restore(stateBin: "/s/state.bin")
    check(res.map(\.execute) == ["migrate-set-parameters", "migrate-set-capabilities", "migrate-incoming"], "restore sequence")
    check(res[2].jsonArguments?["exit-on-error"] as? Bool == false, "incoming does not exit on error")
    check(SnapshotProtocol.status(fromQueryMigrate: ["status": "completed"]) == .completed, "status completed")
    check(SnapshotProtocol.status(fromQueryMigrate: ["status": "failed", "error-desc": "boom"]) == .failed("boom"), "status failed")
    check(SnapshotProtocol.status(fromQueryMigrate: ["status": "active"]) == .inProgress("active"), "status active")

    // argv hash: stable across container moves, fd numbers, -incoming/-S.
    let a1 = ["-M", "ranchu,snapshot-dir=/C1/snap", "-chardev", "socket,id=qmp0,fd=7", "-mon", "chardev=qmp0,mode=control", "-m", "2048"]
    let a2 = ["-M", "ranchu,snapshot-dir=/C2/snap", "-chardev", "socket,id=qmp0,fd=9", "-mon", "chardev=qmp0,mode=control", "-m", "2048", "-S", "-incoming", "defer"]
    check(SnapshotHash.argvHash(a1, replacing: [("/C1", "$ROOT")]) == SnapshotHash.argvHash(a2, replacing: [("/C2", "$ROOT")]), "argv hash normalized")
    check(SnapshotHash.argvHash(a1, replacing: []) != SnapshotHash.argvHash(a1.map { $0 == "2048" ? "4096" : $0 }, replacing: []), "argv hash sensitive")
    // ...and across code buffer sizes (host-side only), but not other accel options.
    let t1 = ["-accel", "tcg,thread=multi,tb-size=512", "-m", "2048"]
    let t2 = ["-accel", "tcg,thread=multi,tb-size=1792", "-m", "2048"]
    let t3 = ["-accel", "tcg,thread=single,tb-size=512", "-m", "2048"]
    check(SnapshotHash.argvHash(t1, replacing: []) == SnapshotHash.argvHash(t2, replacing: []), "argv hash ignores tb-size")
    check(SnapshotHash.argvHash(t1, replacing: []) != SnapshotHash.argvHash(t3, replacing: []), "argv hash keeps accel options")
    // ...and JIT (split-wx) vs TCTI: one snapshot for both engines.
    let jitArgv = ["-accel", AccelMode.tcgJIT(splitWX: true).qemuValue, "-m", "2048"]
    let tctiArgv = ["-accel", AccelMode.tcti.qemuValue(tbSizeMB: 1536), "-m", "2048"]
    check(SnapshotHash.argvHash(jitArgv, replacing: []) == SnapshotHash.argvHash(tctiArgv, replacing: []),
          "argv hash is the same for the JIT and TCTI engines")

    // Image identity: content of small files and size/mtime of large ones.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("va-snap-test-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let big = dir.appendingPathComponent("system.img"), small = dir.appendingPathComponent("initrd")
    try Data(repeating: 1, count: 1000).write(to: big)
    try Data("abc".utf8).write(to: small)
    let i1 = SnapshotHash.imageIdentity(files: [big], contentFiles: [small])
    check(i1 == SnapshotHash.imageIdentity(files: [big], contentFiles: [small]), "image identity stable")
    try Data("abd".utf8).write(to: small)
    check(i1 != SnapshotHash.imageIdentity(files: [big], contentFiles: [small]), "initrd change detected")
    check(SnapshotHash.imageIdentity(files: [big], contentFiles: [], extra: ["boot=a"]) != SnapshotHash.imageIdentity(files: [big], contentFiles: [], extra: ["boot=b"]), "bootconfig change detected")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "snapshot tests threw \(error)")
}

// MARK: JIT decision (QemuEngine.jitDecision)
do {
    func d(enabled: Bool = true, sim: Bool = false, avail: Bool = true, attached: Bool = true, needs: Bool = true,
           jit: Bool = true, tcti: Bool = true, failed: Bool = false) -> JITDecision {
        JITDecision.decide(enabled: enabled, simulator: sim, jitAvailable: avail, debuggerAttached: attached,
                           needsDebugger: needs, jitEngineEmbedded: jit, tctiEngineEmbedded: tcti, lastStartFailed: failed)
    }
    let stik = d()
    check(stik.useJIT && stik.reason == .debugger && !stik.releaseDebugger, "StikDebug launch -> JIT, debugger kept for the engine")
    let off = d(enabled: false)
    check(!off.useJIT && off.reason == .disabled && off.releaseDebugger, "option off -> TCTI and release StikDebug")
    let plain = d(avail: false, attached: false)
    check(!plain.useJIT && plain.reason == .noDebugger && !plain.releaseDebugger, "normal launch -> TCTI, nothing to release")
    let crashed = d(failed: true)
    check(!crashed.useJIT && crashed.reason == .lastStartFailed && crashed.releaseDebugger, "failed JIT start -> TCTI once")
    let oldIOS = d(avail: true, attached: false, needs: false)
    check(oldIOS.useJIT && !oldIOS.releaseDebugger, "pre-iOS 26: CS_DEBUGGED alone is enough")
    let xcode = d(avail: true, attached: true, needs: false, failed: true)
    check(!xcode.useJIT && !xcode.releaseDebugger, "no TXM: never brk at a debugger that is not waiting for it")
    check(d(sim: true, avail: true, attached: false, needs: false).useJIT, "simulator -> JIT")
    check(!d(enabled: false, sim: true, needs: false).useJIT, "simulator, option off, TCTI embedded -> TCTI")
    check(d(enabled: false, sim: true, needs: false, tcti: false).useJIT, "simulator without TCTI -> JIT anyway")
    let tctiOnly = d(jit: false)
    check(!tctiOnly.useJIT && tctiOnly.reason == .noJITEngine && tctiOnly.releaseDebugger, "TCTI-only build")
    check(!d(avail: false, attached: false, tcti: false).useJIT, "JIT-only build without a debugger: nothing runs")
}

print(failures == 0 ? "all \(checks) pure-logic checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
