import Foundation

/// How guest code is translated.
enum AccelMode: Equatable {
    /// TCG with a real JIT (simulator, or device with CS_DEBUGGED). On device
    /// without the dynamic-codesigning entitlement QEMU needs split-wx mirrors.
    case tcgJIT(splitWX: Bool)
    /// UTM's TCTI threaded interpreter (no JIT, plain device builds).
    case tcti

    var qemuValue: String {
        switch self {
        case .tcgJIT(let splitWX):
            // Smaller code buffer on device: split-wx maps it twice.
            return splitWX ? "tcg,thread=multi,tb-size=512,split-wx=on" : "tcg,thread=multi,tb-size=1024"
        case .tcti:
            return "tcg,thread=multi,tb-size=512"
        }
    }
}

struct DiskImage {
    var url: URL
    var format: String       // "raw" or "qcow2"
    var readOnly: Bool

    /// Detects qcow2 by its magic ("QFI\xfb"), raw otherwise.
    static func detect(_ url: URL, readOnly: Bool) -> DiskImage {
        var format = "raw"
        if let h = try? FileHandle(forReadingFrom: url) {
            if let magic = try? h.read(upToCount: 4), magic == Data([0x51, 0x46, 0x49, 0xFB]) {
                format = "qcow2"
            }
            try? h.close()
        }
        return DiskImage(url: url, format: format, readOnly: readOnly)
    }
}

/// QEMU argv equivalent to tools/run-macos.sh, for the in-process engine.
struct QemuArgumentBuilder {
    var machine = "ranchu"
    var accel: AccelMode = .tcgJIT(splitWX: false)
    var cpu = "cortex-a76"
    var cpuCount = 4
    var memoryMB = 2048

    var kernel: URL
    var initrd: URL
    var vendor: DiskImage
    var encryption: DiskImage
    var userdata: DiskImage
    var cache: DiskImage
    var system: DiskImage

    var serialLog: URL
    var hvc0Log: URL
    var logcatLog: URL

    /// Connected socket fd (socketpair) for QMP; QEMU runs in-process so it
    /// can use the fd number directly.
    var qmpFD: Int32?
    /// ranchu: libva_gfx path (`-M ranchu,gfx-lib=`); nil = QEMU's default
    /// lookup (<executable dir>/Frameworks/va_gfx.framework/va_gfx).
    var gfxLib: String?
    var graphics = true
    /// adb on 127.0.0.1:port. ranchu: via va-vsock-pci (the guest's adbd
    /// talks vsock); virt: slirp hostfwd to guest :5555.
    var adbHostPort: Int?
    var vsockGuestCID = 77
    var vsockPipePort = 5000
    var traceEvents: [String] = []

    var isRanchu: Bool { machine.hasPrefix("ranchu") }
    /// M4 snapshot mode: guest RAM in a shared file (mem-path) and the ranchu
    /// `snapshot-dir` (renderer data). See docs/SNAPSHOT.md.
    var ramFile: String?
    var snapshotDir: String?
    /// Restore: `-incoming defer` (+ `-S`, so nothing runs before `cont`).
    var incomingDefer = false
    var extra: [String] = []

    static let kernelCommandLine =
        "8250.nr_uarts=1 no_timer_check console=ttyAMA0,38400 keep_bootcon earlyprintk=ttyAMA0 " +
        "ndns=2 loop.max_part=7 printk.devkmsg=on bootconfig"

    /// QEMU option values use ',' as separator; a literal comma is ",,".
    static func escape(_ path: String) -> String { path.replacingOccurrences(of: ",", with: ",,") }

    private func drive(_ index: Int, _ id: String, _ d: DiskImage) -> [String] {
        var spec = "index=\(index),id=\(id),if=none,file=\(Self.escape(d.url.path)),format=\(d.format)"
        if d.readOnly { spec += ",read-only=on" }
        return ["-drive", spec, "-device", "virtio-blk-device,drive=\(id)"]
    }

    func build() -> [String] {
        var machineArg = machine
        if isRanchu {
            if !graphics {
                machineArg += ",gfx=off"
            } else if let gfxLib {
                machineArg += ",gfx-lib=\(Self.escape(gfxLib))"
            }
            if let snapshotDir { machineArg += ",snapshot-dir=\(Self.escape(snapshotDir))" }
        }
        if ramFile != nil { machineArg += ",memory-backend=ram0" }
        var a: [String] = [
            "-M", machineArg,
            "-accel", accel.qemuValue,
            "-cpu", cpu,
            "-smp", "\(cpuCount)",
            "-m", "\(memoryMB)",
        ]
        if let ramFile {
            a += ["-object", "memory-backend-file,id=ram0,size=\(memoryMB)M,mem-path=\(Self.escape(ramFile)),share=on"]
        }
        a += [
            "-nodefaults",
            "-display", "none",
            "-chardev", "file,id=serial0,path=\(Self.escape(serialLog.path))",
            "-serial", "chardev:serial0",
            "-kernel", kernel.path,
            "-initrd", initrd.path,
            "-append", Self.kernelCommandLine,
        ]
        // Order matters: it fixes the virtio-mmio addresses the image's fstab
        // expects (vendor a003e00, metadata a003c00, userdata a003a00,
        // cache a003800, system a003600).
        a += drive(0, "vendor", vendor)
        a += drive(1, "encrypt", encryption)
        a += drive(2, "userdata", userdata)
        a += drive(3, "cache", cache)
        a += drive(4, "system", system)

        var netdev = "user,id=mynet"
        if !isRanchu, let port = adbHostPort { netdev += ",hostfwd=tcp:127.0.0.1:\(port)-:5555" }
        a += ["-netdev", netdev, "-device", "virtio-net-device,netdev=mynet"]
        a += ["-device", "virtio-rng-device"]
        a += [
            "-chardev", "file,id=forhvc0,path=\(Self.escape(hvc0Log.path))",
            "-chardev", "file,id=forhvc1,path=\(Self.escape(logcatLog.path))",
            "-device", "virtio-serial-pci,ioeventfd=off",
            "-device", "virtconsole,chardev=forhvc0",
            "-device", "virtconsole,chardev=forhvc1",
        ]
        if isRanchu {
            // adbd and the pipe-port services (clipboard ...) use vsock.
            var vsock = "va-vsock-pci,guest-cid=\(vsockGuestCID)"
            if let port = adbHostPort { vsock += ",adb-port=\(port)" }
            vsock += ",pipe-port=\(vsockPipePort)"
            a += ["-device", vsock]
        }
        for t in traceEvents { a += ["-trace", "enable=\(t)"] }
        if let fd = qmpFD {
            a += ["-chardev", "socket,id=qmp0,fd=\(fd)", "-mon", "chardev=qmp0,mode=control"]
        }
        if incomingDefer { a += ["-S", "-incoming", "defer"] }
        return a + extra
    }
}
