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
        // Lets second-stage init load /debug_ramdisk/adb_debug.prop.
        "androidboot.verifiedbootstate": "orange",
    ]

    /// Loaded last by init from the debug fragment (the only host-side way to
    /// set ro.*). Emulation is several times slower than a phone, so the
    /// watchdog and ActivityManager timeouts are scaled.
    static let debugProps: [String: String] = [
        "ro.hw_timeout_multiplier": "5",
    ]

    /// newc cpio archive of regular files plus the trailer (as make_initrd.py).
    static func cpioNewc(_ files: [(String, Data)]) -> Data {
        var out = Data()
        let entries: [(String, Data?)] = files.map { ($0.0, Optional($0.1)) } + [("TRAILER!!!", nil)]
        for (i, entry) in entries.enumerated() {
            let data = entry.1 ?? Data()
            let mode: UInt32 = entry.1 != nil ? 0o100644 : 0
            var name = Data(entry.0.utf8); name.append(0)
            let fields: [UInt32] = [UInt32(300001 + i), mode, 0, 0, 1, 0, UInt32(data.count), 0, 0, 0, 0, UInt32(name.count), 0]
            out.append(contentsOf: Array(("070701" + fields.map { String(format: "%08x", $0) }.joined()).utf8))
            out.append(name)
            out.append(Data(count: (4 - (110 + name.count) % 4) % 4))
            out.append(data)
            out.append(Data(count: (4 - data.count % 4) % 4))
        }
        return out
    }

    /// LZ4 legacy frame of literal-only blocks; the kernel decodes concatenated
    /// legacy frames as one stream, so this can follow the image's ramdisk.
    static func lz4Legacy(_ data: Data) -> Data {
        var out = Data()
        withUnsafeBytes(of: UInt32(0x184C2102).littleEndian) { out.append(contentsOf: $0) }
        var off = 0
        while off < data.count {
            let chunk = data.subdata(in: off..<min(data.count, off + (8 << 20)))
            var blk = Data([UInt8(min(chunk.count, 15) << 4)])
            if chunk.count >= 15 {
                var r = chunk.count - 15
                while r >= 255 { blk.append(255); r -= 255 }
                blk.append(UInt8(r))
            }
            blk.append(chunk)
            withUnsafeBytes(of: UInt32(blk.count).littleEndian) { out.append(contentsOf: $0) }
            out.append(blk)
            off += chunk.count
        }
        return out
    }

    /// /force_debuggable + /adb_debug.prop, appended after the ramdisk.
    static func debugFragment(_ props: [String: String] = debugProps) -> Data {
        let text = props.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
            .map { "\($0)=\(props[$0]!)\n" }.joined()
        return lz4Legacy(cpioNewc([("force_debuggable", Data()), ("adb_debug.prop", Data(text.utf8))]))
    }

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
        data.append(debugFragment())
        data.append(trailer(parameters: parameters(overrides: overrides), ramdiskLength: data.count))
        try data.write(to: output, options: .atomic)
    }
}
