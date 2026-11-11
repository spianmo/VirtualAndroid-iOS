import Foundation
import IOSurface

/// The real engine: QEMU (UTM fork + ranchu board + goldfish pipe services)
/// loaded from an embedded framework and run on its own pthread, with
/// libva_gfx presenting frames as IOSurfaces.
///
/// Expected bundle layout (produced by scripts/embed_engine_frameworks.sh):
///   Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu        JIT build
///   Frameworks/qemu-aarch64-softmmu-tcti.framework/...-tcti                optional TCTI build
///   Frameworks/va_gfx.framework/va_gfx   (or libva_gfx.dylib)              renderer; QEMU dlopens it
final class QemuEngine: VMEngine {
    let displayName = "QEMU"
    weak var delegate: EngineDelegate?

    private var runner: VAQemuRunner?
    private var symbols = VAEngineSymbols()
    private var qmp: QMPClient?
    private weak var frames: FrameSink?
    private var progress: BootProgressTracker?
    private var guestState = VA_GUEST_STOPPED

    // MARK: Discovery

    static let jitFramework = "qemu-aarch64-softmmu"
    static let tctiFramework = "qemu-aarch64-softmmu-tcti"

    private static func frameworkBinary(_ name: String) -> String? {
        guard let dir = Bundle.main.privateFrameworksPath else { return nil }
        let path = "\(dir)/\(name).framework/\(name)"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// TCG backend of the embedded QEMU slice ("tcg" = JIT, "tcti"), written
    /// by scripts/embed_engine_frameworks.sh from qemu-backends.txt.
    static var embeddedBackend: String? {
        guard let url = Bundle.main.url(forResource: "VAEngineBackend", withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The JIT (tcg) engine binary, if embedded.
    private static var jitEngineBinary: String? {
        embeddedBackend == "tcti" ? nil : frameworkBinary(jitFramework)
    }

    /// The TCTI engine binary: the primary framework in a TCTI build, else the
    /// secondary one (next to a JIT primary; VAEngineBackend.txt says tcg).
    private static var tctiEngineBinary: String? {
        embeddedBackend == "tcti" ? frameworkBinary(jitFramework) : frameworkBinary(tctiFramework)
    }

    /// Picks the QEMU build for this process (fixed at launch by `jitDecision`), or nil.
    static func selectFramework() -> (path: String, accel: AccelMode)? {
        if jitDecision.useJIT, let p = jitEngineBinary {
            return (p, .tcgJIT(splitWX: !va_runtime_is_simulator()))
        }
        if let p = tctiEngineBinary { return (p, .tcti) }
        return nil
    }

    static var unavailableReason: String {
        if frameworkBinary(jitFramework) == nil && frameworkBinary(tctiFramework) == nil {
            return "\(jitFramework).framework is not embedded"
        }
        return "the embedded QEMU is a JIT (tcg) build but this process cannot JIT; open the app from StikDebug or embed the TCTI build"
    }

    // MARK: JIT (docs/JIT.md)

    /// The JIT option (start screen; `-VAJIT NO` for one launch). Default on.
    static let jitSettingKey = "VAJIT"
    static var jitEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: jitSettingKey) == nil || d.bool(forKey: jitSettingKey)
    }

    /// Developer: `-VAJIT26 auto|universal|legacy|none` (engine VA_JIT26): how the
    /// engine asks the debugger to prepare the code buffer on iOS 26+. `none`
    /// for Xcode's debugger, which stops on the brk; then the app does not
    /// release the debugger either.
    static var jit26Protocol: String? {
        guard let s = UserDefaults.standard.string(forKey: "VAJIT26"), !s.isEmpty else { return nil }
        return s
    }

    /// Written before a JIT engine starts, removed once the guest is seen running.
    /// Still there at launch: that JIT start crashed or hung (e.g. StikDebug ran a
    /// script that did not prepare the code buffer), so this launch uses TCTI.
    static var jitStartMarker: URL { VMStorage.default.root.appendingPathComponent("jit-start.pending") }

    typealias JITProbe = (available: Bool, attached: Bool, csDebugged: Bool, needsDebugger: Bool)

    private static func sampleJIT() -> JITProbe {
        (va_runtime_jit_available(), va_runtime_debugger_attached(), va_runtime_cs_debugged(),
         va_runtime_jit_needs_debugger())
    }

    /// The facts the decision was made from. Sampled at launch, and again by
    /// `refreshJITDecision()` until the engine starts (P_TRACED changes as soon as
    /// the engine detaches the debugger).
    private(set) static var jitProbe: JITProbe = sampleJIT()

    /// A JIT start marker was left by the previous launch (read once, then removed).
    private static let jitLastStartFailed: Bool = {
        let fm = FileManager.default
        let failed = fm.fileExists(atPath: jitStartMarker.path)
        if failed { try? fm.removeItem(at: jitStartMarker) }
        return failed && !va_runtime_is_simulator()
    }()

    private static func decideJIT() -> JITDecision {
        // -VAJIT26 none (Xcode's debugger, which would stop on the region brk):
        // on a TXM device nothing prepares the code buffer, so no JIT.
        let noRegionCall = jit26Protocol == "none" && jitProbe.needsDebugger
        return JITDecision.decide(enabled: jitEnabled, simulator: va_runtime_is_simulator(),
                           jitAvailable: jitProbe.available && !noRegionCall,
                           debuggerAttached: jitProbe.attached && !noRegionCall,
                           needsDebugger: jitProbe.needsDebugger,
                           jitEngineEmbedded: jitEngineEmbedded,
                           tctiEngineEmbedded: tctiEngineBinary != nil,
                           lastStartFailed: jitLastStartFailed)
    }

    /// JIT or TCTI for this process; fixed once the engine has started.
    private(set) static var jitDecision: JITDecision = decideJIT()

    /// QEMU was started in this process (one VM per process): the decision is final.
    private(set) static var engineStartedInProcess = false

    static var jitEngineEmbedded: Bool { jitEngineBinary != nil }

    /// The previous JIT start of this app failed (start marker found at launch):
    /// this launch runs TCTI whatever debugger comes.
    static var lastJITStartFailed: Bool { jitLastStartFailed }

    /// Samples the debugger state again (e.g. after asking StikDebug to attach)
    /// and re-decides, unless the engine has already started.
    @discardableResult
    static func refreshJITDecision() -> JITDecision {
        guard !engineStartedInProcess else { return jitDecision }
        jitProbe = sampleJIT()
        jitDecision = decideJIT()
        releaseDebuggerIfUnused()
        return jitDecision
    }

    /// A StikDebug script waits for our region call, but this launch will not run
    /// the JIT engine: tell it to detach, or the VM would run under the debugger
    /// (stopping on every signal, killed with StikDebug's connection).
    @discardableResult
    private static func releaseDebuggerIfUnused() -> String? {
        guard jitDecision.releaseDebugger, jitProbe.attached else { return nil }
        if jit26Protocol == "none" { return "JIT: -VAJIT26 none, leaving the debugger attached" }
        let gone = va_runtime_release_jit_debugger()
        jitProbe = sampleJIT()
        jitDecision = decideJIT()
        return gone ? "JIT: told the StikDebug script to detach (no JIT engine this launch)"
                    : "JIT: the debugger is still attached after the detach request"
    }

    /// StikDebug's URL to attach to this (running) process with universal.js, which
    /// speaks the engine's JIT26 calls; StikDebug switches back to the app afterwards.
    static var stikDebugJITURL: URL {
        var c = URLComponents()
        c.scheme = "stikjit"
        c.host = "enable-jit"
        c.queryItems = [URLQueryItem(name: "bundle-id", value: Bundle.main.bundleIdentifier ?? "dev.virtualandroid.app"),
                        URLQueryItem(name: "pid", value: String(getpid())),
                        URLQueryItem(name: "script-name", value: "universal.js")]
        return c.url!
    }

    /// At launch: fix the JIT decision and, when no JIT engine will use the
    /// debugger StikDebug attached, tell it to detach. Returns log lines.
    static func prepareJITAtLaunch() -> [String] {
        let d = jitDecision
        let p = jitProbe
        var lines = ["JIT: \(d.summary) [cs_debugged=\(p.csDebugged) traced=\(p.attached) " +
                     "needs_debugger=\(p.needsDebugger) option=\(jitEnabled)]"]
        if d.releaseDebugger, let line = releaseDebuggerIfUnused() {
            lines.append(line)
        }
        return lines
    }

    static var gfxLibraryPath: String? {
        guard let dir = Bundle.main.privateFrameworksPath else { return nil }
        for p in ["\(dir)/va_gfx.framework/va_gfx", "\(dir)/libva_gfx.dylib"]
            where FileManager.default.fileExists(atPath: p) {
            return p
        }
        return nil
    }

    /// AOT translation cache for the TCTI build (docs/AOT.md): native code for
    /// the hottest guest TBs, bound to the QEMU slice it was embedded with.
    /// QEMU rejects a table that does not match its build and runs plain TCTI.
    /// `-VAAOT NO` runs plain TCTI anyway (A/B timing).
    static var aotLibraryPath: String? {
        let d = UserDefaults.standard
        if d.object(forKey: "VAAOT") != nil && !d.bool(forKey: "VAAOT") { return nil }
        return frameworkBinary("va_aot")
    }

    /// Guest kernel command line with `QemuArgumentBuilder.kernelPerfArguments`
    /// (kpti=0 nokaslr mitigations=off init_on_alloc=0); `-VAKernelPerf NO`
    /// boots without them (A/B timing).
    static var kernelPerf: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "VAKernelPerf") == nil || d.bool(forKey: "VAKernelPerf")
    }

    /// `-VAvCPUQoS <spec>`: QoS class of the TCG vCPU threads (VA_VCPU_QOS, read
    /// by accel/tcg in engine/qemu-ios): one of interactive, initiated, default,
    /// utility, background for all vCPUs, or per index ("0-1:interactive,2-3:utility").
    /// QEMU's default is initiated, below the UIKit main thread.
    static var vcpuQoS: String? {
        guard let s = UserDefaults.standard.string(forKey: "VAvCPUQoS"), !s.isEmpty else { return nil }
        return s
    }

    /// TCG code buffer in MB for this launch: `-VATBSizeMB N` (64...4096), else
    /// for TCTI `AccelMode.tctiTBSizeMB` of the memory available now, else the
    /// accel mode's default (nil).
    static func tbSizeMB(accel: AccelMode, guestMB: Int) -> Int? {
        let forced = UserDefaults.standard.integer(forKey: "VATBSizeMB")
        if (64...4096).contains(forced) { return forced }
        guard accel == .tcti else { return nil }
        return AccelMode.tctiTBSizeMB(availableMB: Int(va_runtime_available_memory() >> 20), guestMB: guestMB)
    }

    static var isAvailable: Bool { selectFramework() != nil }

    static var angleLibraryPath: String? {
        guard let dir = Bundle.main.privateFrameworksPath else { return nil }
        let p = "\(dir)/GLESv2.framework/GLESv2"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// M4: the embedded QEMU knows the ranchu `snapshot-dir` property (the
    /// board's snapshot support). Probed from the binary's strings because an
    /// unknown machine property makes QEMU exit. `-VASnapshotSupport YES|NO`
    /// overrides the probe.
    static let supportsSnapshots: Bool = {
        let d = UserDefaults.standard
        if d.object(forKey: "VASnapshotSupport") != nil { return d.bool(forKey: "VASnapshotSupport") }
        guard let path = probeBinary,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return false }
        return data.range(of: Data("snapshot-dir\0".utf8)) != nil
    }()

    /// The binary the feature probes read: any embedded engine (both are built
    /// from the same source with the same devices), independent of the JIT
    /// decision, which may still change before the engine starts.
    private static var probeBinary: String? { tctiEngineBinary ?? jitEngineBinary }

    /// The embedded QEMU has the ranchu Wi-Fi access point / Bluetooth
    /// controller devices (probed like `supportsSnapshots`: an unknown
    /// `-device` makes QEMU exit).
    static let supportsWifi = embeddedQemuContains("va-wifi-pci\0")
    static let supportsBluetooth = embeddedQemuContains("va-bluetooth\0")
    /// The "va" audio backend (its driver description string).
    static let supportsAudio = embeddedQemuContains("VirtualAndroid host platform audio")

    private static func embeddedQemuContains(_ marker: String) -> Bool {
        guard let path = probeBinary,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return false }
        return data.range(of: Data(marker.utf8)) != nil
    }

    /// The argv (minus the per-launch QMP fd and restore flags) for `config`.
    static func makeBuilder(config: VMLaunchConfig, storage: VMStorage, accel: AccelMode,
                            gfx: String?) -> QemuArgumentBuilder {
        var b = QemuArgumentBuilder(
            machine: config.machine,
            accel: accel,
            cpuCount: config.cpuCount,
            memoryMB: config.memoryMB,
            kernel: storage.kernel,
            initrd: storage.initrd,
            // Device packs may ship system/vendor as qcow2 (sparse: 1.2 GB vs 4 GB raw).
            vendor: DiskImage.detect(storage.vendor, readOnly: true),
            encryption: DiskImage.detect(storage.encryption, readOnly: false),
            userdata: DiskImage.detect(storage.userdata, readOnly: false),
            cache: DiskImage.detect(storage.cache, readOnly: false),
            system: DiskImage.detect(storage.system, readOnly: true),
            serialLog: storage.serialLog,
            hvc0Log: storage.hvc0Log,
            logcatLog: storage.logcatLog)
        b.kernelPerf = kernelPerf
        b.gfxLib = gfx
        b.graphics = gfx != nil
        b.adbHostPort = config.adbPort
        b.wifi = supportsWifi
        b.bluetooth = supportsBluetooth
        b.audio = supportsAudio
        b.traceEvents = config.traceEvents
        if config.snapshotMode {
            b.ramFile = storage.ramImage.path
            b.snapshotDir = storage.snapshotDir.path
        }
        return b
    }

    /// What a snapshot taken by this app/engine/image/config would record.
    static func snapshotIdentity(config: VMLaunchConfig) -> SnapshotIdentity? {
        guard let storage = config.storage, let (_, accel) = selectFramework() else { return nil }
        let engine = engineIdentity
        let gfx = gfxLibraryPath
        let gfxHash = gfx.map { g in
            SnapshotHash.sha256(strings: [FileHashCache.sha256(URL(fileURLWithPath: g)),
                                          angleLibraryPath.map { FileHashCache.sha256(URL(fileURLWithPath: $0)) } ?? "no-angle"])
        } ?? "none"
        let boot = BootConfig.parameters(overrides: bootOverrides(config: config))
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let image = SnapshotHash.imageIdentity(
            files: [storage.kernel, storage.ramdisk, storage.system, storage.vendor],
            contentFiles: storage.exists(storage.manifest) ? [storage.manifest] : [],
            extra: boot)
        let argv = makeBuilder(config: config, storage: storage, accel: accel, gfx: gfx).build()
        let argvHash = SnapshotHash.argvHash(argv, replacing: [(storage.root.path, "$ROOT"),
                                                               (Bundle.main.bundlePath, "$BUNDLE")])
        return SnapshotIdentity(engine: engine, gfx: gfxHash, image: image, argvHash: argvHash)
    }

    /// Snapshot engine identity: the hash of every embedded engine binary. The
    /// JIT and TCTI engines are built from the same source with the same
    /// devices, so a snapshot taken under one restores under the other (the
    /// state holds no translated code); a rebuild of either invalidates it.
    static var engineIdentity: String {
        let bins = [jitEngineBinary, tctiEngineBinary].compactMap { $0 }
        let hashes = bins.map { FileHashCache.sha256(URL(fileURLWithPath: $0)) }
        return hashes.count == 1 ? hashes[0] : SnapshotHash.sha256(strings: hashes)
    }

    /// androidboot.* overrides for this host (bootconfig in the initrd).
    /// androidboot.opengles.version (196608, ANGLE Metal GLES 3.0) and
    /// camera_protocol_ver (0) are BootConfig defaults, as in tools/make_initrd.py.
    static func bootOverrides(config: VMLaunchConfig) -> [String: String] {
        var o = ["androidboot.qemu.skin": "\(config.displayWidth)x\(config.displayHeight)"]
        if let key = config.storage?.adbPublicKey {
            o["androidboot.qemu.adb.pubkey"] = key
        }
        if !supportsWifi {
            o["androidboot.qemu.virtiowifi"] = "0"
        }
        return o
    }

    // MARK: Lifecycle

    func start(config: VMLaunchConfig, host: HostBridge, frames: FrameSink) throws {
        guard let storage = config.storage else { throw EngineError.imageMissing("no storage") }
        // Last look before the choice becomes final: a debugger that attached
        // without a script (StikDebug's plain attach/detach) may be gone already,
        // and on a TXM device the JIT engine cannot run without one.
        let before = Self.jitDecision
        Self.refreshJITDecision()
        if before.useJIT && !Self.jitDecision.useJIT {
            log(2, "JIT: the debugger left before the engine started (StikDebug ran no script?); using TCTI")
        }
        Self.engineStartedInProcess = true
        guard let (path, accel) = Self.selectFramework() else {
            throw EngineError.frameworkMissing(Self.unavailableReason)
        }
        let runner: VAQemuRunner
        do {
            runner = try VAQemuRunner(libraryPath: path)
        } catch {
            throw EngineError.frameworkMissing(error.localizedDescription)
        }
        self.runner = runner
        self.frames = frames

        // Platform callbacks (copied by the engine).
        host.onLog = { [weak self] level, msg in
            DispatchQueue.main.async { guard let self else { return }; self.delegate?.engine(self, log: level, message: msg) }
        }
        host.onGuestState = { [weak self] state in
            DispatchQueue.main.async { self?.guestStateChanged(state) }
        }
        var callbacks = host.makeCallbacks()
        let syms = runner.symbols
        if let set = syms.host_set_callbacks {
            set(&callbacks)
        } else {
            log(2, "engine does not export va_host_set_callbacks; platform bridges disabled")
        }

        // Frames: ranchu loads libva_gfx and hands it this callback (before qemu_init).
        let gfx = Self.gfxLibraryPath
        symbols = syms
        if let setPresent = syms.host_set_present_callback {
            setPresent(qemuPresentTrampoline, Unmanaged.passUnretained(self).toOpaque())
        } else {
            log(2, "engine does not export va_host_set_present_callback: display will stay black")
        }
        if gfx == nil { log(2, "va_gfx.framework not embedded: booting without graphics") }

        // QMP over a socketpair; QEMU owns fds[1].
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw EngineError.startFailed("socketpair: \(String(cString: strerror(errno)))")
        }
        let qmp = QMPClient(fd: fds[0])
        qmp.onEvent = { [weak self] name, data in
            DispatchQueue.main.async { self?.qmpEvent(name, data) }
        }
        qmp.start()
        self.qmp = qmp

        var builder = Self.makeBuilder(config: config, storage: storage, accel: accel, gfx: gfx)
        builder.qmpFD = fds[1]
        builder.incomingDefer = config.restoreStateFile != nil
        builder.tbSizeMB = Self.tbSizeMB(accel: accel, guestMB: config.memoryMB)
        if let tb = builder.tbSizeMB {
            log(1, "TCG code buffer \(tb) MB (\(va_runtime_available_memory() >> 20) MB available)")
        }
        let argv = builder.build()
        log(1, "qemu " + argv.joined(separator: " "))

        var env: [String: String] = [:]
        if let dump = config.dumpFramesDir { env["VA_DUMP_FRAMES"] = dump }
        // The engine's stderr (tcg JIT region preparation, AOT counters, warnings).
        if !va_runtime_is_simulator() && !UserDefaults.standard.bool(forKey: "VAStderrConsole") {
            env["VA_STDERR_FILE"] = storage.vmDir.appendingPathComponent("qemu.out").path
        }
        if case .tcgJIT = accel {
            if let proto = Self.jit26Protocol { env["VA_JIT26"] = proto }
            // TXM: fail the code buffer allocation cleanly when no debugger is there
            // to prepare it, instead of crashing on the first translated block.
            if Self.jitProbe.needsDebugger { env["VA_JIT26_REQUIRED"] = "1" }
            if !va_runtime_is_simulator() { armJITStartMarker(serial: storage.serialLog) }
        }
        if let qos = Self.vcpuQoS { env["VA_VCPU_QOS"] = qos }
        if accel == .tcti {
            if let aot = Self.aotLibraryPath {
                env["QEMU_AOT_LIB"] = aot
            } else {
                log(1, "TCTI without the AOT cache (va_aot.framework not embedded, or -VAAOT NO)")
            }
        }
        // Developer: `-VAEnv "K=V;K2=V2"` adds engine environment variables, e.g. an
        // AOT op capture on the device (QEMU_AOT_CAPTURE/QEMU_AOT_HOT, docs/AOT.md);
        // relative paths are relative to the VM directory (the working directory).
        for item in (UserDefaults.standard.string(forKey: "VAEnv") ?? "").split(separator: ";") {
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, !kv[0].isEmpty {
                env[kv[0]] = kv[1]
                log(1, "engine env \(kv[0])=\(kv[1])")
            }
        }

        if config.restoreStateFile == nil {
            progress = BootProgressTracker(serial: storage.serialLog, logcat: storage.logcatLog) { [weak self] f, msg in
                guard let self else { return }
                self.delegate?.engine(self, bootProgress: f, message: msg)
            }
            progress?.start()
        }

        do {
            try runner.start(withArguments: argv, environment: env, workingDirectory: storage.vmDir.path) {
                [weak self] status, fatal in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !fatal { self.jitStartConfirmed() }
                    self.progress?.stop()
                    self.qmp?.close()
                    self.delegate?.engine(self, didExitWithStatus: status, fatal: fatal,
                                          message: fatal ? "QEMU exited (see serial.log)" : nil)
                }
            }
        } catch {
            qmp.close()
            Darwin.close(fds[1])
            progress?.stop()
            throw EngineError.startFailed(error.localizedDescription)
        }
        if let state = config.restoreStateFile {
            restore(from: state, qmp: qmp)
        } else {
            guestStateChanged(VA_GUEST_BOOTING)
        }
    }

    // MARK: M4 snapshots (docs/SNAPSHOT.md)

    /// QEMU got the `migrate-incoming` request (QMP answered). An engine that exits
    /// before that never read the snapshot (e.g. qemu_init failed allocating the
    /// JIT code buffer), so the snapshot is still good.
    private(set) var restoreStreamRequested = false

    private func restore(from state: URL, qmp: QMPClient) {
        let t0 = Date()
        qmp.run(SnapshotProtocol.restore(stateBin: state.path)) { [weak self] error in
            guard let self else { return }
            // Only a QEMU that answered may have started reading the stream.
            if let q = error as? QMPClient.QMPError, case .closed = q {} else { self.restoreStreamRequested = true }
            if let error {
                self.restoreDone(.failure(error), qmp: qmp)
                return
            }
            qmp.pollMigration(incoming: true, timeout: 120) { result in
                if case .success = result {
                    self.log(1, String(format: "restore: state loaded in %.0f ms", Date().timeIntervalSince(t0) * 1000))
                }
                self.restoreDone(result, qmp: qmp)
            }
        }
    }

    private func restoreDone(_ result: Result<Void, Error>, qmp: QMPClient) {
        if case .failure = result {
            qmp.execute("quit")     // exit-on-error=false kept QEMU alive; stop it cleanly
        }
        DispatchQueue.main.async { self.delegate?.engine(self, restoreFinished: result) }
    }

    func suspend(stateFile: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let qmp else {
            completion(.failure(EngineError.unsupported("engine not running")))
            return
        }
        try? FileManager.default.removeItem(at: stateFile)
        let t0 = Date()
        let finish: (Result<Void, Error>) -> Void = { result in DispatchQueue.main.async { completion(result) } }
        qmp.run(SnapshotProtocol.suspend(stateTmp: stateFile.path)) { [weak self] error in
            if let error { finish(.failure(error)); return }
            qmp.pollMigration(incoming: false, timeout: 25) { result in
                if case .success = result {
                    self?.log(1, String(format: "suspend: migrate completed in %.0f ms", Date().timeIntervalSince(t0) * 1000))
                }
                finish(result)
            }
        }
    }

    func pause() { qmp?.execute("stop") }
    func resume() { qmp?.execute("cont") }
    func requestShutdown() { qmp?.execute("system_powerdown") }
    func forceStop() { qmp?.execute("quit") }

    // MARK: Events

    private func guestStateChanged(_ state: VaGuestState) {
        guestState = state
        if state == VA_GUEST_BOOT_COMPLETED {
            progress?.stop()
        }
        delegate?.engine(self, guestStateChanged: state)
    }

    private func qmpEvent(_ name: String, _ data: [String: Any]) {
        switch name {
        case "STOP": delegate?.engine(self, guestStateChanged: VA_GUEST_PAUSED)
        case "RESUME": delegate?.engine(self, guestStateChanged: guestState == VA_GUEST_PAUSED ? VA_GUEST_BOOTING : guestState)
        case "SHUTDOWN": delegate?.engine(self, guestStateChanged: VA_GUEST_SHUTDOWN)
        default: break
        }
        delegate?.engine(self, log: 0, message: "QMP event \(name)")
    }

    private func log(_ level: Int32, _ msg: String) {
        DispatchQueue.main.async { self.delegate?.engine(self, log: level, message: msg) }
    }

    private var framesReceived: UInt64 = 0
    private var jitMarkerTimer: DispatchSourceTimer?

    /// JIT start marker (see `jitStartMarker`): set now, removed when the guest
    /// visibly runs (a frame arrives or the kernel console grows), or when the
    /// engine exits normally.
    private func armJITStartMarker(serial: URL) {
        let marker = Self.jitStartMarker
        FileManager.default.createFile(atPath: marker.path, contents: Data("\(Date())\n".utf8))
        func size() -> UInt64 { (try? FileManager.default.attributesOfItem(atPath: serial.path)[.size] as? UInt64) ?? 0 }
        let start = size()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.framesReceived > 0 || size() > start { self.jitStartConfirmed() }
        }
        t.resume()
        jitMarkerTimer = t
    }

    private func jitStartConfirmed() {
        guard let t = jitMarkerTimer else { return }
        t.cancel()
        jitMarkerTimer = nil
        try? FileManager.default.removeItem(at: Self.jitStartMarker)
        log(1, "JIT engine is running guest code")
    }

    /// Renderer thread, no BQL. The IOSurface is only guaranteed during the
    /// call; storing it in DisplayFrame retains it (ARC = CFRetain) until the
    /// view replaces it, and libva_gfx never recycles a retained surface.
    fileprivate func present(_ frame: UnsafePointer<VaGfxFrame>) {
        let f = frame.pointee
        guard let raw = f.iosurface else { return }
        let surface = Unmanaged<IOSurfaceRef>.fromOpaque(raw).takeUnretainedValue()
        framesReceived += 1
        if framesReceived == 1 {
            log(1, "first guest frame \(f.width)x\(f.height) (format \(String(format: "%08x", IOSurfaceGetPixelFormat(surface))))")
            DispatchQueue.main.async { self.delegate?.engine(self, bootProgress: 0.6, message: "First frame") }
        }
        frames?.present(DisplayFrame(surface: surface, width: Int(f.width), height: Int(f.height),
                                     rotationDegrees: Int(f.rotation_deg), number: f.frame_number))
    }

    // MARK: EngineInput -> va_engine_*

    func touch(_ points: [VaTouchPoint]) {
        guard let fn = symbols.touch, !points.isEmpty else { return }
        points.withUnsafeBufferPointer { fn($0.baseAddress!, Int32($0.count)) }
    }

    func key(_ linuxKeycode: UInt32, down: Bool) { symbols.key?(linuxKeycode, down) }

    func sensorEvent(_ type: VaSensorType, values: [Float], timestampNs: Int64) {
        guard let fn = symbols.sensor_event else { return }
        values.withUnsafeBufferPointer { fn(type, $0.baseAddress!, Int32($0.count), timestampNs) }
    }

    func locationUpdate(_ location: VaLocation) {
        var l = location
        symbols.location_update?(&l)
    }

    func batteryChanged() { symbols.battery_changed?() }

    func clipboardFromHost(_ text: String) {
        guard let fn = symbols.clipboard_from_host else { return }
        let bytes = Array(text.utf8) + [0]
        bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { fn($0, buf.count - 1) }
        }
    }

    func setDisplayRotation(_ degrees: Int) { symbols.set_display_rotation?(Int32(degrees)) }
}

/// C trampoline for VaGfxPresentFn (renderer thread).
private let qemuPresentTrampoline: VaGfxPresentFn = { opaque, frame in
    guard let opaque, let frame else { return }
    Unmanaged<QemuEngine>.fromOpaque(opaque).takeUnretainedValue().present(frame)
}

/// Estimates cold-boot progress from milestones in the kernel console and
/// logcat files QEMU writes (until the engine reports BOOT_COMPLETED).
final class BootProgressTracker {
    private let files: [URL]
    private var offsets: [URL: UInt64] = [:]
    private var timer: DispatchSourceTimer?
    private var best = 0.0
    private let report: (Double, String) -> Void

    private static let milestones: [(String, Double, String)] = [
        ("Booting Linux on physical CPU", 0.05, "Starting Linux kernel"),
        ("Run /init as init process", 0.12, "Starting init"),
        ("init: Loading SELinux policy", 0.18, "Loading SELinux policy"),
        ("starting service 'zygote", 0.35, "Starting zygote"),
        ("starting service 'bootanim'", 0.45, "Boot animation"),
        ("Entered the Android system server", 0.50, "Starting system server"),
        // logcat runs at *:I (BootConfig): only Info-and-up lines appear there.
        ("SystemServiceManager: Starting phase 500", 0.70, "Starting services"),
        ("System now ready", 0.80, "System ready"),
        ("Boot is finished", 0.95, "Launching home screen"),
    ]

    init(serial: URL, logcat: URL, report: @escaping (Double, String) -> Void) {
        files = [serial, logcat]
        self.report = report
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        for url in files {
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let off = offsets[url] ?? 0
            try? h.seek(toOffset: off)
            guard let data = try? h.readToEnd(), !data.isEmpty else { continue }
            offsets[url] = off + UInt64(data.count)
            let text = String(decoding: data, as: UTF8.self)
            for (needle, value, label) in Self.milestones where value > best && text.contains(needle) {
                best = value
                let b = value
                DispatchQueue.main.async { self.report(b, label) }
            }
        }
    }
}
