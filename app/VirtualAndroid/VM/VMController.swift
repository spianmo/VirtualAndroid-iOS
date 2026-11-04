import Foundation
import os
import SwiftUI
import UIKit

/// Owns the VM lifecycle: image setup, engine selection, boot / pause /
/// resume / shutdown, M4 snapshots (suspend on background, restore on cold
/// launch; state machine in Snapshot.swift) and the platform bridges.
@MainActor
final class VMController: ObservableObject, EngineDelegate {
    enum Phase: Equatable {
        case idle, installing, booting, restoring, running, paused, suspending, suspended, stopping, stopped, failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var bootProgress = 0.0
    @Published private(set) var bootMessage = ""
    @Published private(set) var bootSeconds: Double?
    @Published private(set) var lastError: String?
    @Published private(set) var installProgress = 0.0
    @Published private(set) var installMessage = ""
    @Published private(set) var imageInstalled = false
    @Published private(set) var packLocation: URL?
    @Published private(set) var logLines: [String] = []
    @Published private(set) var activeEngine: EngineKind?
    @Published private(set) var snapshotInfo: String?
    /// QEMU ran in this process already; a (cold) boot needs a relaunch.
    @Published private(set) var relaunchRequired = false
    @Published private(set) var restoreTimings: String?

    // Settings (UserDefaults; launch arguments like `-VAEngine stub` override).
    @Published var engineKind: EngineKind { didSet { defaults.set(engineKind.rawValue, forKey: Keys.engine) } }
    @Published var autoBoot: Bool { didSet { defaults.set(autoBoot, forKey: Keys.autoBoot) } }
    /// M4: snapshot when leaving the app, restore on the next cold launch.
    @Published var fastResume: Bool { didSet { defaults.set(fastResume, forKey: Keys.fastResume) } }
    @Published var rotationMode: DisplayRotationMode {
        didSet {
            defaults.set(rotationMode.rawValue, forKey: Keys.rotation)
            displayView.rotationMode = rotationMode
        }
    }
    @Published var clipboardAutoSync: Bool {
        didSet {
            defaults.set(clipboardAutoSync, forKey: Keys.clipboard)
            host.clipboard.autoSync = clipboardAutoSync
        }
    }
    @Published var keepRunningInBackground: Bool { didSet { defaults.set(keepRunningInBackground, forKey: Keys.background) } }
    @Published var showNavControls: Bool { didSet { defaults.set(showNavControls, forKey: Keys.nav) } }
    let navStartsExpanded: Bool

    let host = HostBridge()
    let storage = VMStorage.default
    let displayView = MetalDisplayView(frame: .zero)
    private(set) var engine: VMEngine?
    private(set) var launchConfig = VMLaunchConfig()
    private var androidRotation = 0
    private var qemuRanInThisProcess = false
    private var lifecycle = VMLifecycle()
    private var pendingConfig: VMLaunchConfig?
    private var pendingKind: EngineKind = .stub
    private var snapshotIdentity: SnapshotIdentity?
    private var suspendStart: Date?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pendingColdBoot = false
    private var restoreMarks: [String] = []
    private var snapshots: SnapshotManager { SnapshotManager(storage: storage) }
    private var bootStart: Date?
    private var didAutoBoot = false
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "dev.virtualandroid.app", category: "vm")

    private enum Keys {
        static let engine = "VAEngine", autoBoot = "VAAutoBoot", fastResume = "VAFastResume"
        static let rotation = "VARotationMode", clipboard = "VAClipboardAutoSync"
        static let background = "VAKeepRunningInBackground", nav = "VANavControls", navExpanded = "VANavExpanded"
        // Developer overrides (launch arguments, e.g. `-VAMachine virt -VAAutoStopAfter 90`).
        static let machine = "VAMachine", autoStopAfter = "VAAutoStopAfter"
        static let forceOrientation = "VAForceOrientation", selfTest = "VASelfTest"
        static let stubDiagnostics = "VAStubDiagnostics"
        static let adbPort = "VAAdbPort", trace = "VATrace", dumpFrames = "VADumpFrames"
        static let script = "VAScript"   // after boot: "wait:5;tap:0.5,0.9;wait:3;key:172"     // e.g. "gnss,camera,mic,tone,sensors,vibrate,copy"
    }

    init() {
        defaults.register(defaults: [Keys.autoBoot: true, Keys.nav: true, Keys.fastResume: true])
        engineKind = EngineKind(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .auto
        autoBoot = defaults.bool(forKey: Keys.autoBoot)
        fastResume = defaults.bool(forKey: Keys.fastResume)
        rotationMode = DisplayRotationMode(rawValue: defaults.string(forKey: Keys.rotation) ?? "") ?? .followDevice
        clipboardAutoSync = defaults.bool(forKey: Keys.clipboard)
        keepRunningInBackground = defaults.bool(forKey: Keys.background)
        showNavControls = defaults.bool(forKey: Keys.nav)
        navStartsExpanded = defaults.bool(forKey: Keys.navExpanded)

        displayView.rotationMode = rotationMode
        host.clipboard.autoSync = clipboardAutoSync
        displayView.onAndroidRotationChange = { [weak self] degrees in
            guard let self else { return }
            self.androidRotation = degrees
            self.host.motion.setSimulatedRotation(degrees)
            self.engine?.setDisplayRotation(degrees)
        }
        refreshImageState()
        log(1, "VirtualAndroid \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"), " +
               "simulator=\(va_runtime_is_simulator()) jit=\(va_runtime_jit_available()) " +
               "mem=\(va_runtime_available_memory() >> 20) MB qemuFramework=\(QemuEngine.isAvailable)")
    }

    // MARK: Derived state

    var phaseName: String { "\(phase)" }

    var isVMActive: Bool {
        [.booting, .restoring, .running, .paused, .suspending, .suspended, .stopping].contains(phase)
    }

    /// The active (or chosen) engine can snapshot (QEMU: board support probed).
    func engineSupportsSnapshots(_ kind: EngineKind) -> Bool {
        kind == .qemu ? QemuEngine.supportsSnapshots : true
    }

    /// `.auto` -> QEMU only when the frameworks are embedded and an image is installed.
    var resolvedEngineKind: EngineKind {
        switch engineKind {
        case .auto: return QemuEngine.isAvailable && imageInstalled ? .qemu : .stub
        default: return engineKind
        }
    }

    var engineSummary: String {
        if let sel = QemuEngine.selectFramework() {
            let accel: String
            switch sel.accel {
            case .tcgJIT(let wx): accel = wx ? "TCG JIT (split-wx)" : "TCG JIT"
            case .tcti: accel = "TCTI (no JIT)"
            }
            return "QEMU framework present · \(accel)"
        }
        return "QEMU unavailable: \(QemuEngine.unavailableReason)"
    }

    var stubDiagnostics: StubDiagnostics? { engine as? StubDiagnostics }

    func refreshImageState() {
        imageInstalled = storage.isImageInstalled
        packLocation = storage.findPack()
        snapshotInfo = snapshots.summary
    }

    // MARK: Launch

    /// First run: install a found image pack automatically, then auto-boot.
    func launchIfNeeded() {
        guard !didAutoBoot else { return }
        didAutoBoot = true
        applyForcedOrientation()
        if !imageInstalled, let pack = packLocation, engineKind != .stub {
            log(1, "first run: installing image pack from \(pack.path)")
            installImagePack(from: pack) { [weak self] ok in
                guard let self, ok, self.autoBoot else { return }
                self.boot()
            }
            return
        }
        if autoBoot, resolvedEngineKind == .stub || imageInstalled {
            boot()
        }
    }

    func boot() {
        guard engine == nil, phase != .installing else { return }
        lastError = nil
        bootSeconds = nil
        bootProgress = 0
        bootMessage = "Starting"
        let kind = resolvedEngineKind
        var cfg = VMLaunchConfig()
        cfg.storage = storage
        if let machine = defaults.string(forKey: Keys.machine), !machine.isEmpty { cfg.machine = machine }
        let port = defaults.integer(forKey: Keys.adbPort)
        #if targetEnvironment(simulator)
        cfg.adbPort = port > 0 ? port : 5570
        #else
        cfg.adbPort = port > 0 ? port : nil
        #endif
        if let t = defaults.string(forKey: Keys.trace), !t.isEmpty {
            cfg.traceEvents = t.split(separator: ",").map(String.init)
        }
        if defaults.bool(forKey: Keys.dumpFrames) {
            cfg.dumpFramesDir = storage.vmDir.appendingPathComponent("frames").path
            try? FileManager.default.createDirectory(atPath: cfg.dumpFramesDir!, withIntermediateDirectories: true)
        }
        guard !(kind == .qemu && qemuRanInThisProcess) else {
            relaunchRequired = true
            fail("QEMU can only run once per app process. Relaunch the app to boot again.")
            return
        }
        if kind == .qemu {
            guard imageInstalled else {
                fail("Android image not installed: missing \(storage.missingImageFiles().joined(separator: ", "))")
                return
            }
        }

        // M4: restore a clean, matching snapshot, else cold boot.
        let supported = engineSupportsSnapshots(kind)
        cfg.snapshotMode = fastResume && supported
        let identity = kind == .qemu ? QemuEngine.snapshotIdentity(config: cfg) : StubEngine.snapshotIdentity(config: cfg)
        snapshotIdentity = identity
        let manifest = snapshots.loadManifest()
        let expectedRam = kind == .qemu ? Int64(cfg.memoryMB) << 20 : 0
        let validity = identity.map {
            SnapshotValidator.validate(manifest: manifest, identity: $0, files: snapshots.files(expectedRamBytes: expectedRam))
        } ?? .invalid("no engine identity")
        let plan = LaunchPlan.decide(snapshotsEnabled: fastResume, engineSupportsSnapshots: supported && identity != nil,
                                     manifest: manifest, validity: validity)
        switch plan {
        case .restore:
            log(1, "snapshot valid (saved \(manifest!.savedAt.formatted(date: .omitted, time: .standard))): restoring")
            cfg.restoreStateFile = storage.stateBin
            lifecycle = VMLifecycle()
            lifecycle.setRestoredBootCompleted(manifest?.guestBootCompleted ?? true)
        case .coldBoot(_, let reason):
            log(1, "cold boot: \(reason)")
            lifecycle = VMLifecycle()
        }
        pendingConfig = cfg
        pendingKind = kind
        restoreMarks = []
        send(.launch(plan))
    }

    /// Starts the engine for the pending config (restore or cold boot).
    private func startEngine() {
        guard var cfg = pendingConfig else { return }
        pendingConfig = nil
        let kind = pendingKind
        if cfg.restoreStateFile == nil {
            // A cold boot starts from fresh RAM and invalidates any snapshot.
            snapshots.discard(keepRAM: false)
        }
        let newEngine: VMEngine
        switch kind {
        case .qemu:
            do {
                try storage.prepareVM(bootOverrides: QemuEngine.bootOverrides(config: cfg))
                if cfg.snapshotMode { try snapshots.prepareDirectory() }
            } catch {
                fail(error.localizedDescription)
                syncPhase(failed: true)
                return
            }
            let available = va_runtime_available_memory()
            if available < UInt64(cfg.memoryMB + 768) << 20 {
                log(2, "only \(available >> 20) MB available for a \(cfg.memoryMB) MB guest " +
                       "(increased-memory-limit entitlement missing?)")
            }
            newEngine = QemuEngine()
            qemuRanInThisProcess = true
        default:
            try? snapshots.prepareDirectory()
            cfg.storage = storage
            newEngine = StubEngine()
        }

        newEngine.delegate = self
        host.target = newEngine
        displayView.input = newEngine
        setInputGate(open: cfg.restoreStateFile == nil)
        displayView.setGuestSize(width: cfg.displayWidth, height: cfg.displayHeight)
        host.battery.start()
        do {
            try newEngine.start(config: cfg, host: host, frames: displayView)
        } catch {
            host.target = nil
            displayView.input = nil
            fail(error.localizedDescription)
            lifecycle.handle(.engineStopped)
            syncPhase(failed: true)
            return
        }
        engine = newEngine
        launchConfig = cfg
        activeEngine = kind
        bootStart = Date()
        newEngine.setDisplayRotation(androidRotation)
        log(1, "\(cfg.restoreStateFile != nil ? "restoring" : "booting") with \(newEngine.displayName) engine " +
               "(machine \(cfg.machine), snapshots \(cfg.snapshotMode ? "on" : "off"))")
        let stopAfter = defaults.double(forKey: Keys.autoStopAfter)
        if stopAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) { [weak self, weak newEngine] in
                guard let self, let newEngine, self.engine === newEngine else { return }
                self.log(1, "VAAutoStopAfter \(stopAfter)s: stopping")
                newEngine.forceStop()
            }
        }
    }

    // MARK: Lifecycle state machine

    private func send(_ event: VMLifecycle.Event) {
        let actions = lifecycle.handle(event)
        for action in actions { perform(action) }
        syncPhase()
    }

    private func perform(_ action: VMLifecycle.Action) {
        switch action {
        case .discardSnapshot:
            snapshots.discard(keepRAM: engine != nil)
            log(1, "snapshot discarded")
            refreshImageState()
        case .startColdBoot, .startRestore:
            startEngine()
        case .showLastFrame:
            if let surface = FrameImage.surface(fromPNG: storage.lastFrame) {
                displayView.showPlaceholder(surface)
                markRestore("last frame shown")
            }
        case .pause:
            setInputGate(open: false)
            engine?.pause()
        case .suspend:
            guard let engine else { return }
            setInputGate(open: false)
            suspendStart = Date()
            engine.suspend(stateFile: storage.stateTmp) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.send(.suspendSaved)
                case .failure(let e):
                    self.log(3, "suspend failed: \(e.localizedDescription)")
                    self.send(.suspendFailed(e.localizedDescription))
                }
                self.endBackgroundTask()
            }
        case .finalizeSnapshot:
            finalizeSnapshot()
        case .markDirty:
            do {
                try snapshots.markDirty()
            } catch {
                // Never run the guest on a clean manifest: drop the snapshot instead.
                log(3, "could not mark snapshot dirty (\(error.localizedDescription)); discarding it")
                snapshots.discard(keepRAM: true)
            }
        case .cont:
            setInputGate(open: true)
            engine?.resume()
        case .requireRelaunch(let message):
            relaunchRequired = true
            lastError = message
            log(3, message)
        }
    }

    private func finalizeSnapshot() {
        guard let identity = snapshotIdentity else { return }
        let ms = Int(Date().timeIntervalSince(suspendStart ?? Date()) * 1000)
        if let frame = displayView.latestFrame(), let image = FrameImage.cgImage(from: frame.surface) {
            _ = FrameImage.writePNG(image, to: storage.lastFrame)
        }
        do {
            try snapshots.finalize(identity: identity, guestBootCompleted: lifecycle.guestBootCompleted, suspendMillis: ms)
            log(1, "snapshot saved: device state \(ms) ms, total \(Int(Date().timeIntervalSince(suspendStart ?? Date()) * 1000)) ms " +
                   "(state.bin \(storage.fileSize(storage.stateBin) >> 10) KB)")
        } catch {
            log(3, "snapshot finalize failed: \(error.localizedDescription)")
            snapshots.discard(keepRAM: true)
        }
        refreshImageState()
    }

    private func syncPhase(failed: Bool = false) {
        if failed { phase = .failed; return }
        switch lifecycle.state {
        case .idle: phase = .idle
        case .coldBooting: if phase != .stopping { phase = .booting }
        case .restoring: phase = .restoring
        case .running: if phase != .stopping { phase = .running }
        case .userPaused, .pausedInBackground: phase = .paused
        case .suspending: phase = .suspending
        case .suspended: phase = .suspended
        case .stopped: phase = .stopped
        case .failed: phase = .failed
        }
    }

    /// Host events (touch, keys, sensors, GNSS, battery, clipboard) reach the
    /// engine only while the guest runs.
    private func setInputGate(open: Bool) {
        host.forwarding = open
        displayView.inputEnabled = open
    }

    private func markRestore(_ what: String) {
        let line = "\(what) +\(ProcessClock.sinceLaunchMs) ms"
        restoreMarks.append(line)
        restoreTimings = restoreMarks.joined(separator: ", ")
        log(1, "restore: \(line) (since process start)")
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: User actions

    /// Settings: delete the snapshot; the next start cold boots.
    func discardSnapshot() {
        send(.discardSnapshot)
    }

    /// VM menu: discard the snapshot and stop; cold boot (stub: right away;
    /// QEMU: after relaunch, since it runs once per process).
    func coldBootNow() {
        send(.discardSnapshot)
        pendingColdBoot = true
        engine?.forceStop()
    }

    func quitApp() {
        exit(0)
    }

    func pause() {
        guard phase == .running || phase == .booting else { return }
        send(.userPause)
    }

    func resume() {
        guard phase == .paused else { return }
        send(.userResume)
    }

    func shutdown() {
        guard let engine, isVMActive else { return }
        phase = .stopping
        engine.requestShutdown()
    }

    func forceStop() {
        engine?.forceStop()
    }

    func sendKey(_ code: UInt32, down: Bool) {
        engine?.key(code, down: down)
    }

    func tapKey(_ code: UInt32, holdSeconds: Double = 0.08) {
        sendKey(code, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) { self.sendKey(code, down: false) }
    }

    func pasteHostClipboard() {
        host.clipboard.pushHostClipboard(force: true)
    }

    // MARK: Developer hooks

    /// `-VAForceOrientation landscapeLeft|landscapeRight|portrait` (the
    /// simulator cannot be rotated from the command line).
    private func applyForcedOrientation() {
        guard let name = defaults.string(forKey: Keys.forceOrientation) else { return }
        let mask: UIInterfaceOrientationMask
        switch name {
        case "landscapeLeft": mask = .landscapeLeft
        case "landscapeRight": mask = .landscapeRight
        case "portraitUpsideDown": mask = .portraitUpsideDown
        default: mask = .portrait
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                Task { @MainActor in self.log(2, "orientation request failed: \(error.localizedDescription)") }
            }
            self.log(1, "requested interface orientation \(name)")
        }
    }

    /// `-VASelfTest YES`: after boot, two fingers at fixed view positions
    /// (30%,35%) and (70%,60%) stay down, then VOL+ and BACK are pressed.
    private func runSelfTest() {
        let v = displayView
        let pts = [CGPoint(x: v.bounds.width * 0.3, y: v.bounds.height * 0.35),
                   CGPoint(x: v.bounds.width * 0.7, y: v.bounds.height * 0.6)]
        log(1, "self-test: touches at \(pts.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " ")) in \(Int(v.bounds.width))x\(Int(v.bounds.height))")
        v.injectTestTouches(pts, down: true)
        tapKey(LinuxKeymap.volumeUp)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.tapKey(LinuxKeymap.back) }
    }

    /// `-VAScript`: wait:S, tap:X,Y (guest 0..1, through the view mapping and
    /// va_engine_touch), key:CODE (down/up like the overlay buttons).
    private func runScript(_ steps: [String]) {
        guard let step = steps.first else { return }
        let rest = Array(steps.dropFirst())
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        var delay = 0.0
        switch parts[0] {
        case "wait":
            delay = Double(arg) ?? 1
        case "tap":
            let xy = arg.split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 {
                let p = displayView.viewPoint(forGuest: CGPoint(x: xy[0], y: xy[1]))
                log(1, "script: tap guest (\(xy[0]), \(xy[1])) = view (\(Int(p.x)), \(Int(p.y)))")
                displayView.injectTestTouches([p], down: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.displayView.injectTestTouches([p], down: false) }
                delay = 0.2
            }
        case "key":
            if let code = UInt32(arg) {
                log(1, "script: key \(LinuxKeymap.name(code))")
                tapKey(code)
                delay = 0.2
            }
        default:
            log(2, "script: unknown step \(step)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.runScript(rest) }
    }

    // MARK: Image setup

    func installImagePack(from url: URL? = nil, securityScoped: Bool = false,
                          completion: ((Bool) -> Void)? = nil) {
        guard let source = url ?? storage.findPack() else {
            fail("No image pack found. Put one in Documents/\(VMStorage.imagePackFolderName) (see README).")
            return
        }
        guard VMStorage.isValidPack(source) || securityScoped else {
            fail("\(source.lastPathComponent) is not a complete image pack")
            return
        }
        phase = .installing
        installProgress = 0
        installMessage = "Preparing"
        let storage = self.storage
        Task.detached(priority: .userInitiated) {
            let scoped = securityScoped && source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                guard VMStorage.isValidPack(source) else {
                    throw EngineError.imageMissing("\(source.lastPathComponent) is not a complete image pack")
                }
                try storage.install(from: source) { fraction, message in
                    Task { @MainActor in
                        self.installProgress = fraction
                        self.installMessage = message
                    }
                }
                await MainActor.run {
                    self.phase = .idle
                    self.refreshImageState()
                    self.log(1, "image installed from \(source.path)")
                    completion?(true)
                }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    self.fail(error.localizedDescription)
                    completion?(false)
                }
            }
        }
    }

    func resetAndroidData() {
        guard !isVMActive else { return }
        do {
            try storage.resetVM()
            log(1, "Android data reset (userdata/cache/metadata/snapshots)")
        } catch {
            fail(error.localizedDescription)
        }
        refreshImageState()
    }

    func deleteImage() {
        guard !isVMActive else { return }
        try? storage.removeImage()
        try? storage.resetVM()
        refreshImageState()
    }

    // MARK: App lifecycle

    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .background:
            guard engine != nil else { return }
            let canSnapshot = launchConfig.snapshotMode || (activeEngine == .stub && fastResume)
            // iOS gives a few seconds; the suspend itself takes ~0.2-2 s.
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VirtualAndroid suspend") { [weak self] in
                    self?.log(2, "background time expired before the suspend finished")
                    self?.endBackgroundTask()
                }
            }
            send(.enterBackground(canSnapshot: canSnapshot, keepRunning: keepRunningInBackground))
            if phase != .suspending { endBackgroundTask() }
        case .active:
            if engine != nil { send(.enterForeground) }
            launchIfNeeded()
        default:
            break
        }
    }

    // MARK: EngineDelegate

    nonisolated func engine(_ engine: VMEngine, guestStateChanged state: VaGuestState) {
        MainActor.assumeIsolated { self.handleGuestState(state, from: engine) }
    }

    nonisolated func engine(_ engine: VMEngine, bootProgress fraction: Double, message: String) {
        MainActor.assumeIsolated {
            guard self.engine === engine, self.phase == .booting else { return }
            self.bootProgress = max(self.bootProgress, fraction)
            self.bootMessage = message
        }
    }

    nonisolated func engine(_ engine: VMEngine, didExitWithStatus status: Int32, fatal: Bool, message: String?) {
        MainActor.assumeIsolated {
            guard self.engine === engine else { return }
            self.host.stopAll()
            self.host.target = nil
            self.displayView.input = nil
            self.engine = nil
            let kind = self.activeEngine
            self.activeEngine = nil
            self.endBackgroundTask()
            let wasRestoring = self.lifecycle.state == .restoring
            if wasRestoring {
                // QEMU exited during the load (e.g. exit() on a bad stream).
                self.send(.restoreFailed(message ?? "engine exited during restore"))
            } else {
                self.send(.engineStopped)
            }
            if fatal || status != 0 {
                self.fail(message ?? "Engine exited with status \(status)")
                self.syncPhase(failed: true)
            } else if !wasRestoring {
                self.log(1, "VM stopped")
            }
            if self.pendingColdBoot {
                self.pendingColdBoot = false
                if kind == .qemu {
                    self.relaunchRequired = true
                    self.lastError = "Snapshot discarded. Relaunch the app to cold boot."
                } else {
                    self.displayView.clearFrame()
                    self.boot()
                }
            }
        }
    }

    nonisolated func engine(_ engine: VMEngine, log level: Int32, message: String) {
        MainActor.assumeIsolated { self.log(level, message) }
    }

    nonisolated func engine(_ engine: VMEngine, restoreFinished result: Result<Void, Error>) {
        MainActor.assumeIsolated {
            guard self.engine === engine else { return }
            switch result {
            case .success:
                self.markRestore("state loaded")
                self.displayView.onNextFrame = { [weak self] in self?.markRestore("first live frame") }
                self.send(.restoreLoaded)
                if self.lifecycle.state == .running {
                    self.markRestore("guest running")
                    self.bootProgress = 1
                    self.runAfterBootHooks()
                }
            case .failure(let e):
                self.log(3, "restore failed: \(e.localizedDescription)")
                self.send(.restoreFailed(e.localizedDescription))
            }
        }
    }

    private func handleGuestState(_ state: VaGuestState, from engine: VMEngine) {
        guard self.engine === engine else { return }
        // Phases come from the lifecycle state machine; the engine's
        // BOOTING/PAUSED reports (QMP STOP/RESUME, or a restored engine that
        // does not know the guest had booted) are informational.
        switch state {
        case VA_GUEST_BOOT_COMPLETED:
            let wasBooting = lifecycle.state == .coldBooting
            send(.bootCompleted)
            guard wasBooting else { return }
            bootProgress = 1
            if let start = bootStart, bootSeconds == nil {
                bootSeconds = Date().timeIntervalSince(start)
                log(1, String(format: "boot completed in %.1f s", bootSeconds!))
            }
            runAfterBootHooks()
        case VA_GUEST_SHUTDOWN:
            phase = .stopping
        default:
            break
        }
    }

    /// Dev hooks that run once the guest is usable (cold boot or restore).
    private func runAfterBootHooks() {
        do {
            if let list = defaults.string(forKey: Keys.stubDiagnostics), let diag = stubDiagnostics {
                let items = Set(list.split(separator: ",").map { String($0) })
                var st = StubDiagnosticsState()
                st.gnss = items.contains("gnss")
                st.camera = items.contains("camera")
                st.mic = items.contains("mic")
                st.tone = items.contains("tone")
                st.allSensors = items.contains("sensors")
                diag.setDiagnostics(st)
                if items.contains("vibrate") { diag.diagnosticVibrate() }
                if items.contains("copy") { diag.diagnosticGuestCopy() }
                log(1, "stub diagnostics: \(list)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self else { return }
                    for line in self.host.statusLines() { self.log(1, "status: \(line)") }
                    self.log(1, "status: display \(self.displayView.framesDrawn) frames drawn")
                }
            }
            if let script = defaults.string(forKey: Keys.script), !script.isEmpty {
                runScript(script.split(separator: ";").map(String.init))
            }
            if defaults.bool(forKey: Keys.selfTest) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.runSelfTest() }
            }
        }
    }

    // MARK: Logging

    func log(_ level: Int32, _ message: String) {
        let prefix = ["D", "I", "W", "E"][Int(max(0, min(3, level)))]
        let line = "\(Self.timeFormatter.string(from: Date())) \(prefix) \(message)"
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        switch level {
        case 3: logger.error("\(message, privacy: .public)")
        case 2: logger.warning("\(message, privacy: .public)")
        default: logger.info("\(message, privacy: .public)")
        }
    }

    private func fail(_ message: String) {
        lastError = message
        if engine == nil, phase != .installing { phase = .failed }
        log(3, message)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
