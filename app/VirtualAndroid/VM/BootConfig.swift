import Foundation

/// Port of tools/make_initrd.py: the image's ramdisk with an Android
/// bootconfig appended. The trailer format (params, NUL, '+' padding, size,
/// checksum, "#BOOTCONFIG\n") is what the kernel's bootconfig parser expects;
/// the output is byte-identical to the Python tool for the same parameters.
enum BootConfig {
    static let defaults: [String: String] = [
        "androidboot.hardware": "ranchu",
        "androidboot.boot_devices": "a003600.virtio_mmio",
        "androidboot.serialno": "VIRTUALANDROID01",
        "androidboot.qemu": "1",
        "androidboot.hardware.gltransport": "pipe",
        "androidboot.qemu.gltransport.name": "pipe",
        "androidboot.qemu.gltransport.drawFlushInterval": "800",
        "androidboot.hardware.vulkan": "ranchu",
        // ANGLE Metal (libva_gfx) offers GLES 3.0 = (3 << 16) | 0.
        "androidboot.opengles.version": "196608",
        "androidboot.debug.hwui.renderer": "skiagl",
        "androidboot.dalvik.vm.heapsize": "512m",
        "androidboot.logcat": "*:V",
        "androidboot.qemu.skin": "1080x2340",
        "androidboot.qemu.vsync": "60",
        "androidboot.qemu.settings.system.screen_off_timeout": "2147483647",
        // The services' qemud camera speaks protocol v0 only.
        "androidboot.qemu.camera_protocol_ver": "0",
        "androidboot.qemu.avd_name": "virtualandroid",
        // Values from the image's VerifiedBootParams.textproto.
        "androidboot.vbmeta.size": "6208",
        "androidboot.vbmeta.hash_alg": "sha256",
        "androidboot.vbmeta.digest": "0aa6a7fa9cc8ff3e3ee12c25c0c91e7dbf3627f0d45dc44a48cbd8d88eb72f59",
        "androidboot.veritymode": "enforcing",
    ]

    /// Bootconfig trailer to append to a ramdisk of `ramdiskLength` bytes.
    static func trailer(parameters: [String: String], ramdiskLength: Int) -> Data {
        var text = Data()
        // Python sorts by code point; keys are ASCII so byte order is identical.
        for key in parameters.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            text.append(contentsOf: Array("\(key)=\"\(parameters[key]!)\"\n".utf8))
        }
        text.append(0)
        // Pad with '+' so the size field starts 4-byte aligned (like the emulator).
        let pad = (4 - (ramdiskLength + text.count) % 4) % 4
        text.append(contentsOf: [UInt8](repeating: UInt8(ascii: "+"), count: pad))
        let checksum = text.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        var out = text
        withUnsafeBytes(of: UInt32(text.count).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: checksum.littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: Array("#BOOTCONFIG\n".utf8))
        return out
    }

    static func parameters(overrides: [String: String]) -> [String: String] {
        defaults.merging(overrides) { _, new in new }
    }

    /// Writes ramdisk + trailer to `output` (atomically).
    static func buildInitrd(ramdisk: URL, output: URL, overrides: [String: String] = [:]) throws {
        var data = try Data(contentsOf: ramdisk, options: .mappedIfSafe)
        data.append(trailer(parameters: parameters(overrides: overrides), ramdiskLength: data.count))
        try data.write(to: output, options: .atomic)
    }
}
