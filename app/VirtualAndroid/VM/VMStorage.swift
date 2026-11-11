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
///         userdata-origin                 manifest "userdata" of the pack the disks came from
///         serial.log hvc0.log logcat.log
///         snapshot/                       M4 (docs/SNAPSHOT.md): ram.img (guest RAM,
///                                         file-backed, shared) state.bin gfx/
///                                         manifest.json last-frame.png
///
/// The "image pack" is a folder with the image files (see app/README.md);
/// userdata/cache must be freshly formatted ext4 qcow2s made on macOS by
/// app/scripts/make_userdata_qcow2.sh, because iOS has no mke2fs. A prebaked
/// pack (tools/prebake_userdata.sh, manifest "userdata": "prebaked-speed")
/// carries a userdata whose first boot, odrefresh and `pm compile -m speed`
/// already ran on the Mac, with its encryptionkey (metadata encryption key)
/// and cache: the three are cloned together, and such a VM boots with the
/// prebaked initrd profile (BootConfig.prebakedDebugProps).
struct VMStorage {
    static let imagePackFolderName = "ImagePack"
    /// Manifest "userdata" values starting with this mark a prebaked pack.
    static let prebakedUserdataPrefix = "prebaked"

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
    /// What the VM's disks were cloned from (the pack's manifest "userdata",
    /// "empty" for formatted-only disks); written when they are created.
    var userdataOrigin: URL { vmDir.appendingPathComponent("userdata-origin") }

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

    // MARK: Prebaked userdata

    /// The pack manifest's "userdata" (nil: empty disks, or no manifest).
    static func userdataKind(manifest: URL) -> String? {
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["userdata"] as? String
    }

    static func isPrebaked(_ kind: String?) -> Bool {
        kind?.hasPrefix(prebakedUserdataPrefix) ?? false
    }

    /// The installed image's userdata template kind.
    var imageUserdataKind: String? { Self.userdataKind(manifest: manifest) }
    var isPrebakedImage: Bool { Self.isPrebaked(imageUserdataKind) }

    /// Kind of the VM's current disks (nil: none yet, or made by an app
    /// version that did not record it, i.e. from an empty template).
    var vmUserdataKind: String? {
        (try? String(contentsOf: userdataOrigin, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The VM's disks came from a prebaked pack: boot with the prebaked profile.
    /// odrefresh records every dalvik.vm.* property in cache-info.xml and
    /// recompiles the boot classpath when one changes (dalvik.vm.usejit too).
    var isPrebakedVM: Bool { Self.isPrebaked(vmUserdataKind) }

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
        // Drop what an earlier pack left and this one does not have (a stale
        // manifest.json would claim a prebaked userdata, a stale
        // encryptionkey.qcow2 would win over this pack's .img).
        for name in Self.requiredPackFiles.flatMap({ $0 }) + Self.optionalPackFiles where !names.contains(name) {
            let url = imageDir.appendingPathComponent(name)
            if exists(url) { try fm.removeItem(at: url) }
        }
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
    /// or after a reset) and (re)builds the initrd. A new VM gets userdata,
    /// encryptionkey and cache from the same pack (userdata is encrypted with
    /// the metadata key in encryptionkey) and records their kind in
    /// `userdataOrigin`. The initrd uses the prebaked profile when the VM's
    /// disks are prebaked; `prebaked` overrides that (A/B). Returns the profile used.
    @discardableResult
    func prepareVM(bootOverrides: [String: String], prebaked: Bool? = nil) throws -> Bool {
        try makeDirectories()
        guard let encTemplate = encryptionTemplate,
              let udTemplate = installedTemplate(["userdata.qcow2"]),
              let cacheTemplate = installedTemplate(["cache.qcow2"]) else {
            throw EngineError.imageMissing(missingImageFiles().joined(separator: ", "))
        }
        let encTarget = vmDir.appendingPathComponent(encTemplate.lastPathComponent)
        let encExisting = ["encryptionkey.qcow2", "encryptionkey.img"].map { vmDir.appendingPathComponent($0) }
        if !exists(userdata) {
            for stale in encExisting + [cache, userdataOrigin] where exists(stale) {
                try fm.removeItem(at: stale)
            }
            try cloneOrCopy(encTemplate, to: encTarget)
            try cloneOrCopy(udTemplate, to: userdata)
            try cloneOrCopy(cacheTemplate, to: cache)
            try (imageUserdataKind ?? "empty").write(to: userdataOrigin, atomically: true, encoding: .utf8)
        } else {
            // Keep the existing userdata; only fill in what is missing.
            if !encExisting.contains(where: exists) { try cloneOrCopy(encTemplate, to: encTarget) }
            if !exists(cache) { try cloneOrCopy(cacheTemplate, to: cache) }
        }
        let profile = prebaked ?? isPrebakedVM
        try BootConfig.buildInitrd(ramdisk: ramdisk, output: initrd, overrides: bootOverrides, prebaked: profile)
        for log in [serialLog, hvc0Log, logcatLog] {
            try? fm.removeItem(at: log)
        }
        return profile
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
