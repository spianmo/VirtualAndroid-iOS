import CryptoKit
import Foundation

// M4 "open the app -> home screen in seconds" (docs/SNAPSHOT.md), app side.
//
// Guest RAM lives in a shared file (memory-backend-file,share=on), so a
// suspend only writes device state: stop -> cpr-reboot + x-ignore-shared ->
// migrate to state.tmp -> rename to state.bin -> manifest clean=true.
//
// A snapshot = ram.img + state.bin + gfx/ + the disks, and it is valid only
// until the guest runs again (running changes RAM and disks in place). Hence:
//  * manifest.clean is set to false *before* every `cont`;
//  * snapshots are taken only when the app goes to the background. We do NOT
//    snapshot right after the first cold boot and keep running: the moment
//    the guest runs on, that snapshot no longer matches ram.img/disks, so a
//    later kill would restore a stale, inconsistent machine. A kill while
//    running (manifest not clean) therefore always means a cold boot.
//
// Everything in this file is pure logic (Foundation + CryptoKit only) and is
// unit-tested on macOS by app/scripts/run_pure_tests.sh.

/// `<snap>/manifest.json`. Field names follow docs/SNAPSHOT.md.
struct SnapshotManifest: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    /// SHA-256 of the QEMU framework binary ("stub-..." for the stub engine).
    var engine: String
    /// SHA-256 of libva_gfx + ANGLE ("none" without graphics).
    var gfx: String
    /// Image identity: installed image files (name/size/mtime), pack manifest, initrd.
    var image: String
    /// SHA-256 of the machine-defining argv (paths normalized, per-launch fds removed).
    var argvHash: String
    /// true only between a completed suspend and the next `cont`.
    var clean: Bool
    var savedAt: Date
    /// Extras (optional, ignored by the validity check).
    var guestBootCompleted: Bool?
    var appVersion: String?
    var suspendMillis: Int?

    enum CodingKeys: String, CodingKey {
        case version, engine, gfx, image, clean
        case argvHash = "argv_hash"
        case savedAt = "saved_at"
        case guestBootCompleted = "guest_boot_completed"
        case appVersion = "app_version"
        case suspendMillis = "suspend_ms"
    }

    var identity: SnapshotIdentity {
        SnapshotIdentity(engine: engine, gfx: gfx, image: image, argvHash: argvHash)
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func encoded() throws -> Data { try Self.encoder().encode(self) }

    static func decode(_ data: Data) -> SnapshotManifest? {
        try? decoder().decode(SnapshotManifest.self, from: data)
    }
}

/// What the running app + engine + image would produce now.
struct SnapshotIdentity: Equatable {
    var engine: String
    var gfx: String
    var image: String
    var argvHash: String
}

/// Facts about the snapshot directory, gathered by the caller.
struct SnapshotFiles: Equatable {
    var stateBinBytes: Int64 = 0      // 0 = missing
    var ramImgBytes: Int64 = 0        // logical size (st_size); 0 = missing
    var expectedRamBytes: Int64 = 0
    var hasLastFrame = false
    /// The VM's writable disks exist (they are part of the snapshot).
    var disksPresent = true
}

enum SnapshotValidity: Equatable {
    case valid
    case invalid(String)

    var isValid: Bool { self == .valid }
}

enum SnapshotValidator {
    static func validate(manifest: SnapshotManifest?, identity: SnapshotIdentity,
                         files: SnapshotFiles) -> SnapshotValidity {
        guard let m = manifest else { return .invalid("no snapshot") }
        guard m.version == SnapshotManifest.currentVersion else {
            return .invalid("manifest version \(m.version) != \(SnapshotManifest.currentVersion)")
        }
        guard m.clean else { return .invalid("not clean (app was killed while the VM was running)") }
        if m.engine != identity.engine { return .invalid("engine changed") }
        if m.gfx != identity.gfx { return .invalid("renderer changed") }
        if m.image != identity.image { return .invalid("image changed") }
        if m.argvHash != identity.argvHash { return .invalid("machine configuration changed") }
        guard files.stateBinBytes > 0 else { return .invalid("state.bin missing") }
        guard files.ramImgBytes > 0 else { return .invalid("ram.img missing") }
        if files.expectedRamBytes > 0, files.ramImgBytes != files.expectedRamBytes {
            return .invalid("ram.img is \(files.ramImgBytes) bytes, expected \(files.expectedRamBytes)")
        }
        guard files.disksPresent else { return .invalid("VM disks missing") }
        return .valid
    }
}

/// What to do at launch.
enum LaunchPlan: Equatable {
    case restore
    /// discard = delete stale snapshot files first (always, unless none exist).
    case coldBoot(discard: Bool, reason: String)

    static func decide(snapshotsEnabled: Bool, engineSupportsSnapshots: Bool,
                       manifest: SnapshotManifest?, validity: SnapshotValidity) -> LaunchPlan {
        let anything = manifest != nil
        guard snapshotsEnabled else { return .coldBoot(discard: anything, reason: "snapshots disabled") }
        guard engineSupportsSnapshots else {
            return .coldBoot(discard: anything, reason: "engine has no snapshot support")
        }
        switch validity {
        case .valid: return .restore
        case .invalid(let why): return .coldBoot(discard: anything, reason: why)
        }
    }
}

// MARK: - Lifecycle state machine

/// VM lifecycle with snapshots. The reducer is pure; VMController executes the
/// returned actions in order. Invariant: `.markDirty` always precedes `.cont`
/// while a clean manifest exists, so the guest never runs on a clean snapshot.
struct VMLifecycle: Equatable {
    enum State: Equatable {
        case idle
        case coldBooting
        case restoring
        case running
        /// Stopped by the user (menu Pause) while in the foreground.
        case userPaused
        case suspending
        /// Saved; QEMU alive, paused in postmigrate (or restored and paused).
        case suspended
        /// Background without a snapshot (snapshots off / suspend failed).
        case pausedInBackground
        case stopped
        case failed(String)
    }

    enum Event: Equatable {
        case launch(LaunchPlan)
        case bootCompleted
        case restoreLoaded
        case restoreFailed(String)
        /// canSnapshot = snapshots enabled and supported by the engine.
        case enterBackground(canSnapshot: Bool, keepRunning: Bool)
        case suspendSaved
        case suspendFailed(String)
        case enterForeground
        case userPause
        case userResume
        case engineStopped
        /// User: "Discard snapshot / cold boot".
        case discardSnapshot
    }

    enum Action: Equatable {
        case discardSnapshot
        case startColdBoot
        case showLastFrame
        case startRestore
        case pause
        case suspend
        /// Rename state.tmp -> state.bin, write manifest clean=true, last-frame.png.
        case finalizeSnapshot
        /// Rewrite manifest with clean=false (must hit disk before `.cont`).
        case markDirty
        case cont
        /// QEMU cannot be re-initialized in-process: a cold boot needs a relaunch.
        case requireRelaunch(String)
    }

    private(set) var state: State = .idle
    /// A clean manifest exists on disk.
    private(set) var snapshotClean = false
    /// The guest had reached sys.boot_completed (restored from the manifest).
    private(set) var guestBootCompleted = false
    /// Foreground requested while a suspend was in flight.
    private(set) var resumeRequested = false
    /// The user paused before going to background: stay paused on return.
    private(set) var userPausedBeforeBackground = false
    private(set) var inBackground = false

    init() {}

    /// For a restore: whether the snapshot was taken after boot completed.
    mutating func setRestoredBootCompleted(_ v: Bool) { guestBootCompleted = v }

    private mutating func contActions() -> [Action] {
        if snapshotClean {
            snapshotClean = false
            return [.markDirty, .cont]
        }
        return [.cont]
    }

    private mutating func runAfterSnapshot() -> [Action] {
        if userPausedBeforeBackground {
            userPausedBeforeBackground = false
            state = .userPaused     // stays paused; snapshot remains clean until the user resumes
            return []
        }
        state = .running
        return contActions()
    }

    @discardableResult
    mutating func handle(_ event: Event) -> [Action] {
        switch (state, event) {
        case (.idle, .launch(let plan)), (.stopped, .launch(let plan)), (.failed, .launch(let plan)):
            switch plan {
            case .restore:
                state = .restoring
                snapshotClean = true
                return [.showLastFrame, .startRestore]
            case .coldBoot(let discard, _):
                state = .coldBooting
                snapshotClean = false
                guestBootCompleted = false
                return discard ? [.discardSnapshot, .startColdBoot] : [.startColdBoot]
            }

        case (_, .discardSnapshot):
            // Deletes the files only. A running QEMU keeps running; a cold boot
            // after that needs a new process (QEMU is once per process).
            snapshotClean = false
            return [.discardSnapshot]

        case (_, .engineStopped):
            state = .stopped
            resumeRequested = false
            return []

        case (.coldBooting, .bootCompleted):
            guestBootCompleted = true
            state = .running
            return []      // by design no snapshot here (see top of file)
        case (_, .bootCompleted):
            guestBootCompleted = true
            return []

        case (.restoring, .restoreLoaded):
            if inBackground {
                state = .suspended   // loaded but untouched: snapshot still valid
                return []
            }
            state = .running
            return contActions()
        case (.restoring, .restoreFailed(let why)):
            state = .failed(why)
            snapshotClean = false
            return [.discardSnapshot, .requireRelaunch("Snapshot restore failed (\(why)). It was discarded; relaunch the app to cold boot.")]

        case (.coldBooting, .enterBackground(let canSnapshot, let keepRunning)),
             (.running, .enterBackground(let canSnapshot, let keepRunning)),
             (.userPaused, .enterBackground(let canSnapshot, let keepRunning)):
            inBackground = true
            let wasUserPaused = state == .userPaused
            if keepRunning && !wasUserPaused { return [] }
            if canSnapshot {
                userPausedBeforeBackground = wasUserPaused
                state = .suspending
                resumeRequested = false
                return wasUserPaused ? [.suspend] : [.pause, .suspend]
            }
            if wasUserPaused { return [] }
            state = .pausedInBackground
            return [.pause]
        case (.restoring, .enterBackground):
            inBackground = true
            return []
        case (_, .enterBackground):
            inBackground = true
            return []

        case (.suspending, .suspendSaved):
            snapshotClean = true
            if resumeRequested {
                resumeRequested = false
                return [.finalizeSnapshot] + runAfterSnapshot()
            }
            state = .suspended
            return [.finalizeSnapshot]
        case (.suspending, .suspendFailed):
            snapshotClean = false
            if resumeRequested {
                resumeRequested = false
                if userPausedBeforeBackground {
                    userPausedBeforeBackground = false
                    state = .userPaused
                    return [.discardSnapshot]
                }
                state = .running
                return [.discardSnapshot, .cont]
            }
            state = .pausedInBackground
            return [.discardSnapshot]

        case (.suspending, .enterForeground):
            inBackground = false
            resumeRequested = true
            return []
        case (.suspended, .enterForeground):
            inBackground = false
            return runAfterSnapshot()
        case (.pausedInBackground, .enterForeground):
            inBackground = false
            state = .running
            return contActions()
        case (.restoring, .enterForeground):
            inBackground = false
            return []
        case (_, .enterForeground):
            inBackground = false
            return []

        case (.running, .userPause), (.coldBooting, .userPause):
            state = .userPaused
            return [.pause]
        case (.userPaused, .userResume):
            state = .running
            return contActions()

        default:
            return []
        }
    }
}

// MARK: - QMP protocol (docs/SNAPSHOT.md)

enum SnapshotProtocol {
    struct Command: Equatable {
        var execute: String
        var arguments: [String: AnyHashable]?

        /// Plain Foundation values for JSONSerialization.
        var jsonArguments: [String: Any]? {
            arguments.map { $0.mapValues(SnapshotProtocol.plain) }
        }
    }

    static func plain(_ v: AnyHashable) -> Any {
        if let d = v.base as? [String: AnyHashable] { return d.mapValues(plain) }
        if let a = v.base as? [AnyHashable] { return a.map(plain) }
        return v.base
    }

    static func fileChannel(_ path: String) -> [AnyHashable] {
        [["channel-type": "main",
          "addr": ["transport": "file", "filename": path, "offset": 0] as [String: AnyHashable]] as [String: AnyHashable]]
    }

    /// Both directions set the same mode and capability.
    static let setup: [Command] = [
        Command(execute: "migrate-set-parameters", arguments: ["mode": "cpr-reboot"]),
        Command(execute: "migrate-set-capabilities",
                arguments: ["capabilities": [["capability": "x-ignore-shared", "state": true] as [String: AnyHashable]] as [AnyHashable]]),
    ]

    /// Suspend: stop, setup, migrate to the temp file; then poll
    /// `query-migrate` until "completed" (runstate postmigrate).
    static func suspend(stateTmp: String) -> [Command] {
        [Command(execute: "stop", arguments: nil)] + setup +
            [Command(execute: "migrate", arguments: ["channels": fileChannel(stateTmp)])]
    }

    /// Restore (QEMU started with `-incoming defer`): setup, then load;
    /// poll `query-migrate` until "completed", then `cont`.
    static func restore(stateBin: String) -> [Command] {
        setup + [Command(execute: "migrate-incoming",
                         arguments: ["channels": fileChannel(stateBin), "exit-on-error": false])]
    }

    enum MigrationStatus: Equatable {
        case inProgress(String), completed, failed(String)
    }

    /// Interprets a `query-migrate` reply.
    static func status(fromQueryMigrate reply: [String: Any]?) -> MigrationStatus {
        let status = reply?["status"] as? String ?? "none"
        switch status {
        case "completed": return .completed
        case "failed", "cancelled", "cancelling":
            return .failed(reply?["error-desc"] as? String ?? status)
        default: return .inProgress(status)
        }
    }
}

// MARK: - Hashing

enum SnapshotHash {
    static func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func sha256(strings: [String]) -> String {
        var h = SHA256()
        for s in strings {
            h.update(data: Data(s.utf8))
            h.update(data: Data([0]))
        }
        return hex(h.finalize())
    }

    /// Streams a file (no full read into memory).
    static func sha256(fileAt url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        while let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty {
            h.update(data: chunk)
        }
        return hex(h.finalize())
    }

    /// argv identity: replaces volatile prefixes (container/bundle paths can
    /// move between installs) and drops per-launch options (QMP fd, -incoming, -S).
    static func argvHash(_ argv: [String], replacing prefixes: [(String, String)]) -> String {
        var out: [String] = []
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "-S" { i += 1; continue }
            if a == "-incoming" { i += 2; continue }
            if (a == "-chardev" || a == "-mon"), i + 1 < argv.count,
               argv[i + 1].contains("id=qmp0") || argv[i + 1].hasPrefix("chardev=qmp0") {
                i += 2
                continue
            }
            var s = a
            for (prefix, token) in prefixes where !prefix.isEmpty {
                s = s.replacingOccurrences(of: prefix, with: token)
            }
            out.append(s)
            i += 1
        }
        return sha256(strings: out)
    }

    /// Image identity without reading multi-GB files: name, size and mtime
    /// of each file, plus the contents of small ones (pack manifest, initrd).
    static func imageIdentity(files: [URL], contentFiles: [URL], extra: [String] = []) -> String {
        var parts: [String] = extra
        for url in files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(url.lastPathComponent):\(size):\(Int64(mtime))")
        }
        for url in contentFiles {
            parts.append("\(url.lastPathComponent):\(sha256(fileAt: url) ?? "missing")")
        }
        return sha256(strings: parts)
    }
}
