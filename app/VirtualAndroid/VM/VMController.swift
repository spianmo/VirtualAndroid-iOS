import Foundation
import os
import SwiftUI
import UIKit

/// Owns the VM lifecycle: image setup, engine selection, boot / pause /
/// resume / shutdown, snapshots (placeholder) and the platform bridges.
@MainActor
final class VMController: ObservableObject, EngineDelegate {
    enum Phase: Equatable {
        case idle, installing, booting, running, paused, stopping, stopped, failed
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

    // Settings (UserDefaults; launch arguments like `-VAEngine stub` override).
    @Published var engineKind: EngineKind { didSet { defaults.set(engineKind.rawValue, forKey: Keys.engine) } }
    @Published var autoBoot: Bool { didSet { defaults.set(autoBoot, forKey: Keys.autoBoot) } }
    @Published var quickBoot: Bool { didSet { defaults.set(quickBoot, forKey: Keys.quickBoot) } }
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
    private var autoPaused = false
    private var qemuRanInThisProcess = false
    private var bootStart: Date?
    private var didAutoBoot = false
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "dev.virtualandroid.app", category: "vm")

    private enum Keys {
        static let engine = "VAEngine", autoBoot = "VAAutoBoot", quickBoot = "VAQuickBoot"
        static let rotation = "VARotationMode", clipboard = "VAClipboardAutoSync"
        static let background = "VAKeepRunningInBackground", nav = "VANavControls", navExpanded = "VANavExpanded"
    }

    init() {
        defaults.register(defaults: [Keys.autoBoot: true, Keys.nav: true])
        engineKind = EngineKind(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .auto
        autoBoot = defaults.bool(forKey: Keys.autoBoot)
        quickBoot = defaults.bool(forKey: Keys.quickBoot)
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

    var isVMActive: Bool { [.booting, .running, .paused, .stopping].contains(phase) }

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
        return "QEMU framework not embedded (stub only)"
    }

    var stubDiagnostics: StubDiagnostics? { engine as? StubDiagnostics }

    func refreshImageState() {
        imageInstalled = storage.isImageInstalled
        packLocation = storage.findPack()
        let meta = SnapshotStore(url: storage.snapshotMetadata).load()
        snapshotInfo = meta.map { "\($0.tag) · \($0.engine) · \($0.created.formatted(date: .abbreviated, time: .shortened))" }
    }

    // MARK: Launch

    func launchIfNeeded() {
        guard !didAutoBoot else { return }
        didAutoBoot = true
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
        let engineName = kind == .qemu ? "qemu" : "stub"

        let snapshots = SnapshotStore(url: storage.snapshotMetadata)
        if quickBoot, let meta = snapshots.load() {
            if meta.fingerprint == SnapshotStore.fingerprint(storage: storage, config: cfg, engine: engineName) {
                cfg.restoreSnapshotTag = meta.tag
                log(1, "quick boot: restoring snapshot \(meta.tag)")
            } else {
                log(2, "quick boot: snapshot does not match this image/config, cold booting")
                snapshots.invalidate()
            }
        }

        let newEngine: VMEngine
        switch kind {
        case .qemu:
            guard !qemuRanInThisProcess else {
                fail("QEMU can only run once per app process. Relaunch the app to boot again.")
                return
            }
            guard imageInstalled else {
                fail("Android image not installed: missing \(storage.missingImageFiles().joined(separator: ", "))")
                return
            }
            do {
                try storage.prepareVM(bootOverrides: [:])
            } catch {
                fail(error.localizedDescription)
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
            newEngine = StubEngine()
        }

        newEngine.delegate = self
        host.engine = newEngine
        displayView.input = newEngine
        displayView.setGuestSize(width: cfg.displayWidth, height: cfg.displayHeight)
        host.battery.start()
        do {
            try newEngine.start(config: cfg, host: host, frames: displayView)
        } catch {
            host.engine = nil
            displayView.input = nil
            fail(error.localizedDescription)
            return
        }
        engine = newEngine
        launchConfig = cfg
        activeEngine = kind
        bootStart = Date()
        phase = .booting
        newEngine.setDisplayRotation(androidRotation)
        log(1, "booting with \(newEngine.displayName) engine")
    }

    func pause() {
        guard phase == .running || phase == .booting else { return }
        engine?.pause()
    }

    func resume() {
        guard phase == .paused else { return }
        engine?.resume()
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

    /// M4 placeholder: save a quick-boot snapshot of the running machine.
    func saveQuickBootSnapshot() {
        guard let engine, engine.supportsSnapshots, phase == .running else { return }
        let tag = SnapshotStore.quickBootTag
        let engineName = activeEngine == .qemu ? "qemu" : "stub"
        let fingerprint = SnapshotStore.fingerprint(storage: storage, config: launchConfig, engine: engineName)
        log(1, "saving snapshot \(tag)…")
        engine.saveSnapshot(tag: tag) { [weak self] error in
            guard let self else { return }
            if let error {
                self.log(3, "snapshot failed: \(error.localizedDescription)")
                return
            }
            try? self.storage.makeDirectories()
            try? SnapshotStore(url: self.storage.snapshotMetadata).save(
                .init(tag: tag, created: Date(), fingerprint: fingerprint, engine: engineName))
            self.log(1, "snapshot \(tag) saved")
            self.refreshImageState()
        }
    }

    func deleteSnapshot() {
        SnapshotStore(url: storage.snapshotMetadata).invalidate()
        refreshImageState()
    }

    // MARK: Image setup

    func installImagePack(from url: URL? = nil, securityScoped: Bool = false) {
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
                }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    self.fail(error.localizedDescription)
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
            if !keepRunningInBackground, phase == .running || phase == .booting {
                autoPaused = true
                pause()
            }
        case .active:
            if autoPaused {
                autoPaused = false
                resume()
            }
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
            self.host.engine = nil
            self.displayView.input = nil
            self.engine = nil
            self.activeEngine = nil
            if fatal || status != 0 {
                self.fail(message ?? "Engine exited with status \(status)")
            } else {
                self.phase = .stopped
                self.log(1, "VM stopped")
            }
        }
    }

    nonisolated func engine(_ engine: VMEngine, log level: Int32, message: String) {
        MainActor.assumeIsolated { self.log(level, message) }
    }

    private func handleGuestState(_ state: VaGuestState, from engine: VMEngine) {
        guard self.engine === engine else { return }
        switch state {
        case VA_GUEST_BOOTING:
            if phase != .stopping { phase = .booting }
        case VA_GUEST_BOOT_COMPLETED:
            phase = .running
            bootProgress = 1
            if let start = bootStart, bootSeconds == nil {
                bootSeconds = Date().timeIntervalSince(start)
                log(1, String(format: "boot completed in %.1f s", bootSeconds!))
            }
            if quickBoot, launchConfig.restoreSnapshotTag == nil {
                // First cold boot with quick boot on: snapshot once the home screen settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.saveQuickBootSnapshot() }
            }
        case VA_GUEST_PAUSED:
            if phase != .stopping { phase = .paused }
        case VA_GUEST_SHUTDOWN:
            phase = .stopping
        default:
            break
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
