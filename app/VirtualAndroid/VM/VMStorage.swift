import Darwin
import Foundation

/// On-disk layout (all under Application Support, excluded from backups):
///
///     VirtualAndroid/
///       images/android-33-arm64-v8a/      read-only image + pristine disk templates
///         kernel-ranchu ramdisk.img system.img vendor.img
///         encryptionkey.img|.qcow2 userdata.qcow2 cache.qcow2 manifest.json
///       vms/default/                      the VM's writable state
///         encryptionkey.(img|qcow2) userdata.qcow2 cache.qcow2 initrd
///         serial.log hvc0.log logcat.log
///         snapshot/                       M4 (docs/SNAPSHOT.md): ram.img (guest RAM,
///                                         file-backed, shared) state.bin gfx/
///                                         manifest.json last-frame.png
///
/// The "image pack" is a folder with the image files (see app/README.md);
/// userdata/cache must be freshly formatted ext4 qcow2s made on macOS by
/// app/scripts/make_userdata_qcow2.sh, because iOS has no mke2fs.
struct VMStorage {
    static let imagePackFolderName = "ImagePack"

    let root: URL

    static var `default`: VMStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VMStorage(root: base.appendingPathComponent("VirtualAndroid", isDirectory: true))
    }

    var imageDir: URL { root.appendingPathComponent("images/android-33-arm64-v8a", isDirectory: true) }
    var vmDir: URL { root.appendingPathComponent("vms/default", isDirectory: true) }

    // Image (read-only).
    var kernel: URL { imageDir.appendingPathComponent("kernel-ranchu") }
    var ramdisk: URL { imageDir.appendingPathComponent("ramdisk.img") }
    var system: URL { imageDir.appendingPathComponent("system.img") }
    var vendor: URL { imageDir.appendingPathComponent("vendor.img") }
    var manifest: URL { imageDir.appendingPathComponent("manifest.json") }

    // Writable VM state.
    var userdata: URL { vmDir.appendingPathComponent("userdata.qcow2") }
    var cache: URL { vmDir.appendingPathComponent("cache.qcow2") }
    var initrd: URL { vmDir.appendingPathComponent("initrd") }
    var serialLog: URL { vmDir.appendingPathComponent("serial.log") }
    var hvc0Log: URL { vmDir.appendingPathComponent("hvc0.log") }
    var logcatLog: URL { vmDir.appendingPathComponent("logcat.log") }

    // Snapshot (M4).
    var snapshotDir: URL { vmDir.appendingPathComponent("snapshot", isDirectory: true) }
    var ramImage: URL { snapshotDir.appendingPathComponent("ram.img") }
    var stateBin: URL { snapshotDir.appendingPathComponent("state.bin") }
    var stateTmp: URL { snapshotDir.appendingPathComponent("state.tmp") }
    var snapshotManifest: URL { snapshotDir.appendingPathComponent("manifest.json") }
    var lastFrame: URL { snapshotDir.appendingPathComponent("last-frame.png") }
    var snapshotGfxDir: URL { snapshotDir.appendingPathComponent("gfx", isDirectory: true) }

    /// Files an image pack must contain. Either name of each tuple is accepted.
    static let requiredPackFiles: [[String]] = [
        ["kernel-ranchu"], ["ramdisk.img"], ["system.img"], ["vendor.img"],
        ["encryptionkey.qcow2", "encryptionkey.img"], ["userdata.qcow2"], ["cache.qcow2"],
    ]
    /// adbkey.pub (dev builds): the Mac's ~/.android/adbkey.pub, passed as
    /// androidboot.qemu.adb.pubkey so adbd accepts that host without a prompt.
    static let optionalPackFiles = ["manifest.json", "VerifiedBootParams.textproto", "build.prop", "adbkey.pub"]

    private var fm: FileManager { .default }

    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// Template inside the installed image for a pack entry (first match).
    func installedTemplate(_ names: [String]) -> URL? {
        names.map { imageDir.appendingPathComponent($0) }.first(where: exists)
    }

    var encryptionTemplate: URL? { installedTemplate(["encryptionkey.qcow2", "encryptionkey.img"]) }

    var encryption: URL {
        let qcow = vmDir.appendingPathComponent("encryptionkey.qcow2")
        if exists(qcow) { return qcow }
        let raw = vmDir.appendingPathComponent("encryptionkey.img")
        if exists(raw) { return raw }
        return encryptionTemplate?.pathExtension == "img" ? raw : qcow
    }

    var isImageInstalled: Bool {
        Self.requiredPackFiles.allSatisfy { installedTemplate($0) != nil }
    }

    func missingImageFiles() -> [String] {
        Self.requiredPackFiles.filter { installedTemplate($0) == nil }.map { $0.joined(separator: "|") }
    }

    /// Dev adb public key: Documents/adbkey.pub overrides the image pack's.
    var adbPublicKey: String? {
        var candidates: [URL] = []
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs.appendingPathComponent("adbkey.pub"))
        }
        candidates.append(imageDir.appendingPathComponent("adbkey.pub"))
        for url in candidates {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                let key = s.replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !key.contains("\"") { return key }
            }
        }
        return nil
    }

    var isVMCreated: Bool { exists(userdata) && exists(cache) && exists(encryption) }

    // MARK: Image pack discovery

    /// Candidate pack locations: Documents/ImagePack (side-loaded with simctl
    /// or the Files app) and an ImagePack folder inside the app bundle.
    func packCandidates() -> [URL] {
        var urls: [URL] = []
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(docs.appendingPathComponent(Self.imagePackFolderName, isDirectory: true))
        }
        if let bundled = Bundle.main.url(forResource: Self.imagePackFolderName, withExtension: nil) {
            urls.append(bundled)
        }
        return urls
    }

    static func isValidPack(_ dir: URL) -> Bool {
        requiredPackFiles.allSatisfy { names in
            names.contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }

    func findPack() -> URL? { packCandidates().first(where: Self.isValidPack) }

    // MARK: Install

    /// Copies (APFS clones where possible) the pack into `imageDir`.
    func install(from pack: URL, progress: (Double, String) -> Void) throws {
        try makeDirectories()
        let names = Self.requiredPackFiles.compactMap { names in
            names.first { fm.fileExists(atPath: pack.appendingPathComponent($0).path) }
        } + Self.optionalPackFiles.filter { fm.fileExists(atPath: pack.appendingPathComponent($0).path) }
        let sizes = names.map { fileSize(pack.appendingPathComponent($0)) }
        let total = max(1, sizes.reduce(0, +))
        var done: Int64 = 0
        for (name, size) in zip(names, sizes) {
            progress(Double(done) / Double(total), "Copying \(name)")
            try cloneOrCopy(pack.appendingPathComponent(name), to: imageDir.appendingPathComponent(name))
            done += size
        }
        try excludeFromBackup(root)
        progress(1, "Image installed")
    }

    /// Creates the VM's writable disks from the pristine templates (first run
    /// or after a reset) and (re)builds the initrd.
    func prepareVM(bootOverrides: [String: String]) throws {
        try makeDirectories()
        guard let encTemplate = encryptionTemplate,
              let udTemplate = installedTemplate(["userdata.qcow2"]),
              let cacheTemplate = installedTemplate(["cache.qcow2"]) else {
            throw EngineError.imageMissing(missingImageFiles().joined(separator: ", "))
        }
        let encTarget = vmDir.appendingPathComponent(encTemplate.lastPathComponent)
        if !exists(encTarget) { try cloneOrCopy(encTemplate, to: encTarget) }
        if !exists(userdata) { try cloneOrCopy(udTemplate, to: userdata) }
        if !exists(cache) { try cloneOrCopy(cacheTemplate, to: cache) }
        try BootConfig.buildInitrd(ramdisk: ramdisk, output: initrd, overrides: bootOverrides)
        for log in [serialLog, hvc0Log, logcatLog] {
            try? fm.removeItem(at: log)
        }
    }

    /// Factory reset: drops userdata/cache/metadata and snapshots.
    func resetVM() throws {
        if exists(vmDir) { try fm.removeItem(at: vmDir) }
        try makeDirectories()
    }

    func removeImage() throws {
        if exists(imageDir) { try fm.removeItem(at: imageDir) }
    }

    // MARK: Helpers

    func makeDirectories() throws {
        try fm.createDirectory(at: imageDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: vmDir, withIntermediateDirectories: true)
    }

    func fileSize(_ url: URL) -> Int64 {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Bytes actually allocated (sparse/cloned files use less than their size).
    func allocatedSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }

    func cloneOrCopy(_ src: URL, to dst: URL) throws {
        if exists(dst) { try fm.removeItem(at: dst) }
        // COPYFILE_CLONE: clonefile(2) on APFS (instant, no extra space), falls
        // back to a data copy across volumes.
        let rc = copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_CLONE))
        if rc != 0 {
            let err = String(cString: strerror(errno))
            throw EngineError.startFailed("copy \(src.lastPathComponent) failed: \(err)")
        }
    }

    func excludeFromBackup(_ url: URL) throws {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try u.setResourceValues(values)
    }

    func freeDiskBytes() -> Int64 {
        let values = try? root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
