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
    let supportsSnapshots = true

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

    static var isAvailable: Bool { selectFramework() != nil }

    private static let glesVersionKey = "VAGlesVersion"

    /// GLES version the renderer offers, via va_gfx_get_gles_version()
    /// (documented as valid after va_gfx_init, which QEMU calls later; so a
    /// value seen in an earlier run is cached and used for the bootconfig).
    static func queryGlesVersion() -> (Int32, Int32)? {
        guard let path = gfxLibraryPath, let h = dlopen(path, RTLD_NOW | RTLD_LOCAL),
              let sym = dlsym(h, "va_gfx_get_gles_version") else { return nil }
        typealias Fn = @convention(c) (UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
        var major: Int32 = 0, minor: Int32 = 0
        guard unsafeBitCast(sym, to: Fn.self)(&major, &minor) == 0, major >= 2 else { return nil }
        UserDefaults.standard.set(Int((major << 16) | minor), forKey: glesVersionKey)
        return (major, minor)
    }

    /// androidboot.* overrides for this host (bootconfig in the initrd).
    static func bootOverrides(config: VMLaunchConfig) -> [String: String] {
        var o = ["androidboot.qemu.skin": "\(config.displayWidth)x\(config.displayHeight)"]
        if let (major, minor) = queryGlesVersion() {
            o["androidboot.opengles.version"] = "\((major << 16) | minor)"
        } else if let cached = UserDefaults.standard.object(forKey: glesVersionKey) as? Int {
            o["androidboot.opengles.version"] = "\(cached)"
        } else if gfxLibraryPath != nil {
            o["androidboot.opengles.version"] = "196608"    // ANGLE Metal offers GLES 3.0 (gfx/README.md)
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
        var syms = runner.symbols
        if let set = syms.host_set_callbacks {
            set(&callbacks)
        } else {
            log(2, "engine does not export va_host_set_callbacks; platform bridges disabled")
        }

        // Frames: needs the (proposed) present hook, see README "Engine integration".
        let gfx = Self.gfxLibraryPath
        if let gfx { _ = runner.resolvePresentCallback(fromLibrary: gfx) }
        syms = runner.symbols
        symbols = syms
        if let setPresent = syms.set_present_callback {
            setPresent(qemuPresentTrampoline, Unmanaged.passUnretained(self).toOpaque())
        } else {
            log(2, "no va_engine_set_present_callback/va_gfx_set_present_callback: display will stay black")
        }

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

        var builder = QemuArgumentBuilder(
            machine: config.machine,
            accel: accel,
            cpuCount: config.cpuCount,
            memoryMB: config.memoryMB,
            kernel: storage.kernel,
            initrd: storage.initrd,
            vendor: DiskImage(url: storage.vendor, format: "raw", readOnly: true),
            encryption: DiskImage.detect(storage.encryption, readOnly: false),
            userdata: DiskImage.detect(storage.userdata, readOnly: false),
            cache: DiskImage.detect(storage.cache, readOnly: false),
            system: DiskImage(url: storage.system, format: "raw", readOnly: true),
            serialLog: storage.serialLog,
            hvc0Log: storage.hvc0Log,
            logcatLog: storage.logcatLog)
        builder.qmpFD = fds[1]
        builder.loadvmTag = config.restoreSnapshotTag
        #if targetEnvironment(simulator)
        builder.adbHostPort = 5570    // `adb connect 127.0.0.1:5570` (run-macos.sh uses 5555, run_sim.sh 5590)
        #endif
        let argv = builder.build()
        log(1, "qemu " + argv.joined(separator: " "))

        var env: [String: String] = [:]
        if let gfx { env["VA_GFX_LIBRARY"] = gfx }
        env["VA_DISPLAY"] = "\(config.displayWidth)x\(config.displayHeight)@\(config.displayDPI)/\(config.refreshHz)"

        progress = BootProgressTracker(serial: storage.serialLog, logcat: storage.logcatLog) { [weak self] f, msg in
            guard let self else { return }
            self.delegate?.engine(self, bootProgress: f, message: msg)
        }
        progress?.start()

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
        guestStateChanged(VA_GUEST_BOOTING)
    }

    func pause() { qmp?.execute("stop") }
    func resume() { qmp?.execute("cont") }
    func requestShutdown() { qmp?.execute("system_powerdown") }
    func forceStop() { qmp?.execute("quit") }

    func saveSnapshot(tag: String, completion: @escaping (Error?) -> Void) {
        guard let qmp else { completion(EngineError.unsupported("engine not running")); return }
        // HMP savevm is synchronous and simple; switch to the snapshot-save job for M4.
        qmp.human("savevm \(tag)") { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let out):
                    let text = out as? String ?? ""
                    completion(text.isEmpty ? nil : EngineError.startFailed(text))
                case .failure(let e):
                    completion(e)
                }
            }
        }
    }

    // MARK: Events

    private func guestStateChanged(_ state: VaGuestState) {
        guestState = state
        if state == VA_GUEST_BOOT_COMPLETED {
            progress?.stop()
            _ = Self.queryGlesVersion()   // renderer initialized by now: cache for the next bootconfig
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

    fileprivate func present(_ frame: UnsafePointer<VaGfxFrame>) {
        let f = frame.pointee
        guard let raw = f.iosurface else { return }
        let surface = Unmanaged<IOSurfaceRef>.fromOpaque(raw).takeUnretainedValue()
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
