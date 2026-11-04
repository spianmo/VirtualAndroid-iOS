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

    /// Picks the QEMU build that can run in this process, or nil.
    static func selectFramework() -> (path: String, accel: AccelMode)? {
        let jit = va_runtime_jit_available()
        let splitWX = !va_runtime_is_simulator()
        if !jit, let p = frameworkBinary(tctiFramework) { return (p, .tcti) }
        if let p = frameworkBinary(jitFramework) {
            switch embeddedBackend {
            case "tcti": return (p, .tcti)
            default: return jit ? (p, .tcgJIT(splitWX: splitWX)) : nil    // a JIT build needs JIT
            }
        }
        if let p = frameworkBinary(tctiFramework) { return (p, .tcti) }
        return nil
    }

    static var unavailableReason: String {
        if frameworkBinary(jitFramework) == nil && frameworkBinary(tctiFramework) == nil {
            return "\(jitFramework).framework is not embedded"
        }
        return "the embedded QEMU is a JIT (tcg) build but this process cannot JIT; attach a debugger or embed the TCTI build"
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
        guard let path = selectFramework()?.path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return false }
        return data.range(of: Data("snapshot-dir\0".utf8)) != nil
    }()

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
        b.gfxLib = gfx
        b.graphics = gfx != nil
        b.adbHostPort = config.adbPort
        b.traceEvents = config.traceEvents
        if config.snapshotMode {
            b.ramFile = storage.ramImage.path
            b.snapshotDir = storage.snapshotDir.path
        }
        return b
    }

    /// What a snapshot taken by this app/engine/image/config would record.
    static func snapshotIdentity(config: VMLaunchConfig) -> SnapshotIdentity? {
        guard let storage = config.storage, let (path, accel) = selectFramework() else { return nil }
        let engine = FileHashCache.sha256(URL(fileURLWithPath: path))
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

    /// androidboot.* overrides for this host (bootconfig in the initrd).
    /// androidboot.opengles.version (196608, ANGLE Metal GLES 3.0) and
    /// camera_protocol_ver (0) are BootConfig defaults, as in tools/make_initrd.py.
    static func bootOverrides(config: VMLaunchConfig) -> [String: String] {
        var o = ["androidboot.qemu.skin": "\(config.displayWidth)x\(config.displayHeight)"]
        if let key = config.storage?.adbPublicKey {
            o["androidboot.qemu.adb.pubkey"] = key
        }
        return o
    }

    // MARK: Lifecycle

    func start(config: VMLaunchConfig, host: HostBridge, frames: FrameSink) throws {
        guard let storage = config.storage else { throw EngineError.imageMissing("no storage") }
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
        let argv = builder.build()
        log(1, "qemu " + argv.joined(separator: " "))

        var env: [String: String] = [:]
        if let dump = config.dumpFramesDir { env["VA_DUMP_FRAMES"] = dump }
        if accel == .tcti {
            if let aot = Self.aotLibraryPath {
                env["QEMU_AOT_LIB"] = aot
            } else {
                log(1, "TCTI without the AOT cache (va_aot.framework not embedded, or -VAAOT NO)")
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

    private func restore(from state: URL, qmp: QMPClient) {
        let t0 = Date()
        qmp.run(SnapshotProtocol.restore(stateBin: state.path)) { [weak self] error in
            guard let self else { return }
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
        ("SystemServerTiming: StartActivityManagerReadyPhase", 0.70, "Starting services"),
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
