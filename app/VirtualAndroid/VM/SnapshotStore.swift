import CryptoKit
import Foundation

/// M4 placeholder: bookkeeping for a "quick boot" whole-machine snapshot.
///
/// Plan: after the first cold boot reaches the home screen, save the machine
/// with QMP `savevm` into the qcow2 disks (read-only raw disks are skipped by
/// QEMU; every *writable* disk must be qcow2, which is why the image pack
/// ships userdata/cache/encryptionkey as qcow2). On the next launch, if the
/// fingerprint still matches, boot with `-loadvm <tag>` and the guest resumes
/// at the home screen in seconds. Snapshot loading also needs the gfx
/// renderer and goldfish devices to save/restore state (not done yet).
struct SnapshotStore {
    static let quickBootTag = "va-quickboot"

    struct Metadata: Codable {
        var tag: String
        var created: Date
        var fingerprint: String
        var engine: String
    }

    let url: URL

    func load() -> Metadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    func save(_ m: Metadata) throws {
        let data = try JSONEncoder().encode(m)
        try data.write(to: url, options: .atomic)
    }

    func invalidate() {
        try? FileManager.default.removeItem(at: url)
    }

    /// A snapshot is only valid for the exact image + machine configuration.
    static func fingerprint(storage: VMStorage, config: VMLaunchConfig, engine: String) -> String {
        var parts = [engine, "\(config.memoryMB)", "\(config.cpuCount)", "\(config.displayWidth)x\(config.displayHeight)"]
        for url in [storage.kernel, storage.system, storage.vendor, storage.ramdisk] {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(url.lastPathComponent):\(size):\(Int(mtime))")
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
