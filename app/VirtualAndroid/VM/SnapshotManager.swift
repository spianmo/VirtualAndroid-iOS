import Foundation

/// File side of M4 snapshots (paths in VMStorage, protocol in Snapshot.swift).
struct SnapshotManager {
    let storage: VMStorage
    private var fm: FileManager { .default }

    func loadManifest() -> SnapshotManifest? {
        guard let data = try? Data(contentsOf: storage.snapshotManifest) else { return nil }
        return SnapshotManifest.decode(data)
    }

    func writeManifest(_ m: SnapshotManifest) throws {
        try fm.createDirectory(at: storage.snapshotDir, withIntermediateDirectories: true)
        // Atomic replace; durability across power loss is not required (an app
        // kill keeps the page cache).
        try m.encoded().write(to: storage.snapshotManifest, options: .atomic)
    }

    /// clean=false must be on disk before the guest runs again.
    func markDirty() throws {
        guard var m = loadManifest(), m.clean else { return }
        m.clean = false
        try writeManifest(m)
    }

    func files(expectedRamBytes: Int64) -> SnapshotFiles {
        SnapshotFiles(stateBinBytes: storage.fileSize(storage.stateBin),
                      ramImgBytes: storage.fileSize(storage.ramImage),
                      expectedRamBytes: expectedRamBytes,
                      hasLastFrame: storage.exists(storage.lastFrame),
                      disksPresent: storage.isVMCreated)
    }

    /// Promote state.tmp -> state.bin, then write the clean manifest.
    func finalize(identity: SnapshotIdentity, guestBootCompleted: Bool, suspendMillis: Int) throws {
        guard storage.exists(storage.stateTmp) else {
            throw EngineError.startFailed("state.tmp missing after suspend")
        }
        if storage.exists(storage.stateBin) { try fm.removeItem(at: storage.stateBin) }
        try fm.moveItem(at: storage.stateTmp, to: storage.stateBin)
        let m = SnapshotManifest(version: SnapshotManifest.currentVersion, engine: identity.engine, gfx: identity.gfx,
                                 image: identity.image, argvHash: identity.argvHash, clean: true, savedAt: Date(),
                                 guestBootCompleted: guestBootCompleted,
                                 appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                                 suspendMillis: suspendMillis)
        try writeManifest(m)
    }

    /// Deletes the snapshot. `keepRAM`: ram.img is the live RAM of a running
    /// QEMU (unlinking it would detach the guest's memory from the directory).
    func discard(keepRAM: Bool) {
        for url in [storage.snapshotManifest, storage.stateBin, storage.stateTmp, storage.lastFrame, storage.snapshotGfxDir] {
            try? fm.removeItem(at: url)
        }
        if !keepRAM { try? fm.removeItem(at: storage.ramImage) }
    }

    func prepareDirectory() throws {
        try fm.createDirectory(at: storage.snapshotDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: storage.snapshotGfxDir, withIntermediateDirectories: true)
        try storage.excludeFromBackup(storage.snapshotDir)
    }

    var summary: String? {
        guard let m = loadManifest() else { return nil }
        let size = storage.fileSize(storage.stateBin) >> 20
        let ram = storage.allocatedSize(storage.ramImage) >> 20
        return "\(m.clean ? "ready" : "stale (VM ran after it)") · \(m.savedAt.formatted(date: .abbreviated, time: .standard))" +
            " · state \(size) MB, RAM file \(ram) MB" + (m.suspendMillis.map { " · saved in \($0) ms" } ?? "")
    }
}

/// SHA-256 of large binaries, cached by (path, size, mtime) so a launch only
/// stats the files.
enum FileHashCache {
    private static let key = "VAFileHashCache"

    static func sha256(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(size):\(mtime)"
        var cache = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let id = url.lastPathComponent + "|" + url.deletingLastPathComponent().lastPathComponent
        if let entry = cache[id], entry.hasPrefix(stamp + "=") {
            return String(entry.dropFirst(stamp.count + 1))
        }
        let hash = SnapshotHash.sha256(fileAt: url) ?? "missing"
        cache[id] = stamp + "=" + hash
        UserDefaults.standard.set(cache, forKey: key)
        return hash
    }
}

/// Process start time, for "launch -> interactive" measurements.
enum ProcessClock {
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0 {
            let tv = info.kp_proc.p_starttime
            return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
        }
        return Date()
    }()

    static var sinceLaunchMs: Int { Int(Date().timeIntervalSince(processStart) * 1000) }
}
