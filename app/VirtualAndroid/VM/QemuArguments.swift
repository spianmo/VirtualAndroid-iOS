import Foundation

/// How guest code is translated.
enum AccelMode: Equatable {
    /// TCG with a real JIT (simulator, or device with CS_DEBUGGED). On device
    /// without the dynamic-codesigning entitlement QEMU needs split-wx mirrors.
    case tcgJIT(splitWX: Bool)
    /// UTM's TCTI threaded interpreter (no JIT, plain device builds).
    case tcti

    var qemuValue: String { qemuValue(tbSizeMB: nil) }

    /// `tbSizeMB` overrides the code buffer size (TCTI: see `tctiTBSizeMB`).
    func qemuValue(tbSizeMB: Int?) -> String {
        switch self {
        case .tcgJIT(let splitWX):
            // Smaller code buffer on device: split-wx maps it twice.
            return splitWX ? "tcg,thread=multi,tb-size=\(tbSizeMB ?? 512),split-wx=on"
                           : "tcg,thread=multi,tb-size=\(tbSizeMB ?? 1024)"
        case .tcti:
            return "tcg,thread=multi,tb-size=\(tbSizeMB ?? 512)"
        }
    }

    /// TCTI code buffer for a process with `availableMB` left (os_proc_available_memory)
    /// and a `guestMB` guest: everything above the guest RAM and a 1.5 GB reserve
    /// (renderer, AOT table, the app), in 256 MB steps, 512...2048 MB. TCTI streams
    /// are large (a full boot plus ten minutes of UI fills about 1 GB), and a full
    /// buffer means tb_flush: every vCPU stops and all code, AOT hits included, is
    /// translated again. The buffer is plain anonymous memory, so only what is used
    /// counts against the memory limit.
    static func tctiTBSizeMB(availableMB: Int, guestMB: Int) -> Int {
        let spare = (availableMB - guestMB - 1536) / 256 * 256
        return min(max(spare, 512), 2048)
    }
}

/// JIT or TCTI for this launch, decided once per process at launch
/// (QemuEngine.jitDecision). Pure logic, unit-tested.
///
/// On a device JIT needs a debugger: StikDebug launches the app attached
/// (CS_DEBUGGED), and on iOS 26+ (TXM) its script must still be attached when
/// QEMU allocates the code buffer, because the debugger makes that region
/// executable (engine tcg/region.c). QEMU then detaches it.
struct JITDecision: Equatable {
    enum Reason: Equatable {
        /// Simulator: JIT always works.
        case simulator
        /// Launched with a debugger (StikDebug) that can enable JIT.
        case debugger
        /// The JIT option is off.
        case disabled
        /// No debugger: the app was opened normally, not from StikDebug.
        case noDebugger
        /// The previous launch with JIT ended before the engine got going.
        case lastStartFailed
        /// The app was built without a JIT engine (TCTI only).
        case noJITEngine
    }

    var useJIT: Bool
    var reason: Reason
    /// A debugger attached for JIT (StikDebug's script) waits for us, but no
    /// JIT engine will ask it to prepare memory: tell it to detach now.
    var releaseDebugger: Bool

    static func decide(enabled: Bool, simulator: Bool, jitAvailable: Bool,
                       debuggerAttached: Bool, needsDebugger: Bool,
                       jitEngineEmbedded: Bool, tctiEngineEmbedded: Bool,
                       lastStartFailed: Bool) -> JITDecision {
        // Only a debugger that waits for the engine's region call can be released.
        let waiting = debuggerAttached && needsDebugger
        let possible = simulator || jitAvailable
        let jit = JITDecision(useJIT: true, reason: simulator ? .simulator : .debugger, releaseDebugger: false)
        func tcti(_ reason: Reason) -> JITDecision {
            JITDecision(useJIT: false, reason: reason, releaseDebugger: waiting)
        }
        guard jitEngineEmbedded else { return tcti(.noJITEngine) }
        // Nothing else to run: JIT wherever it works, whatever the option says.
        guard tctiEngineEmbedded else {
            return possible ? jit : JITDecision(useJIT: false, reason: .noDebugger, releaseDebugger: false)
        }
        guard enabled else { return tcti(.disabled) }
        guard possible else { return tcti(.noDebugger) }
        guard simulator || !lastStartFailed else { return tcti(.lastStartFailed) }
        return jit
    }

    /// One line for the start screen.
    var summary: String {
        switch reason {
        case .simulator: return "JIT"
        case .debugger: return "JIT (enabled by StikDebug)"
        case .disabled: return "TCTI + AOT cache: JIT is turned off"
        case .noDebugger: return "TCTI + AOT cache: open VirtualAndroid from StikDebug to use JIT"
        case .lastStartFailed: return "TCTI + AOT cache: the last JIT start failed; JIT is tried again on the next launch"
        case .noJITEngine: return "TCTI + AOT cache: this build has no JIT engine"
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
    /// TCG code buffer (`-accel ...,tb-size=`); nil = the accel mode's default.
    /// Not part of the snapshot identity (SnapshotHash.argvHash drops it).
    var tbSizeMB: Int?

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
    /// ranchu: Wi-Fi access point for the guest's wlan0 (`va-wifi-pci`, on its
    /// own slirp network) and the Bluetooth controller on the virtio-serial
    /// port "bluetooth" (`va-bluetooth`), as tools/run-macos.sh. Off for an
    /// engine built before these devices existed (QemuEngine probes it).
    var wifi = true
    var bluetooth = true
    /// ranchu: virtio-sound on the engine's "va" audio backend, i.e. the
    /// platform's speaker_*/mic_* callbacks (AudioBridge).
    var audio = true
    var traceEvents: [String] = []

    var isRanchu: Bool { machine.hasPrefix("ranchu") }
    /// M4 snapshot mode: guest RAM in a shared file (mem-path) and the ranchu
    /// `snapshot-dir` (renderer data). See docs/SNAPSHOT.md.
    var ramFile: String?
    var snapshotDir: String?
    /// Restore: `-incoming defer` (+ `-S`, so nothing runs before `cont`).
    var incomingDefer = false
    var extra: [String] = []

    /// Adds `kernelPerfArguments` to the kernel command line (default;
    /// `-VAKernelPerf NO` turns it off for A/B runs).
    var kernelPerf = true

    static let kernelCommandLine =
        "8250.nr_uarts=1 no_timer_check console=ttyAMA0,38400 keep_bootcon earlyprintk=ttyAMA0 " +
        "ndns=2 loop.max_part=7 loop.max_loop=64 printk.devkmsg=on bootconfig mac80211_hwsim.radios=0"
    /// Guest kernel settings for emulation (as tools/run-macos.sh, VA_KERNEL_PERF=0
    /// drops them): no KPTI (KASLR forces it on; then every kernel entry/exit
    /// writes TTBR1 with another ASID and QEMU flushes the whole softmmu TLB),
    /// no KASLR, no side-channel mitigations, no zeroing of every page allocation.
    static let kernelPerfArguments = "kpti=0 nokaslr mitigations=off init_on_alloc=0"

    static func fullKernelCommandLine(perf: Bool) -> String {
        perf ? kernelCommandLine + " " + kernelPerfArguments : kernelCommandLine
    }

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
            "-accel", accel.qemuValue(tbSizeMB: tbSizeMB),
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
            // Engine-owned console (ringbuf, still logged to serialLog): the
            // engine types on it for the guest clock sync after a restore and
            // the guest setup at boot (hw/android/guest_time.c).
            "-chardev", "ringbuf,id=vaconsole,size=65536,logfile=\(Self.escape(serialLog.path))",
            "-serial", "chardev:vaconsole",
            "-kernel", kernel.path,
            "-initrd", initrd.path,
            "-append", Self.fullKernelCommandLine(perf: kernelPerf),
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
        if isRanchu && wifi {
            a += ["-netdev", "user,id=wifi0,dhcpstart=10.0.2.16", "-device", "va-wifi-pci,netdev=wifi0"]
        }
        a += ["-device", "virtio-rng-device"]
        a += [
            "-chardev", "file,id=forhvc0,path=\(Self.escape(hvc0Log.path))",
            "-chardev", "file,id=forhvc1,path=\(Self.escape(logcatLog.path))",
            "-device", "virtio-serial-pci,ioeventfd=off",
            "-device", "virtconsole,chardev=forhvc0",
            "-device", "virtconsole,chardev=forhvc1",
        ]
        if isRanchu && bluetooth {
            a += ["-device", "va-bluetooth"]
        }
        if isRanchu && audio {
            a += ["-audiodev", "va,id=snd0,out.frequency=48000,in.frequency=48000,in.channels=1",
                  "-device", "virtio-sound-pci,audiodev=snd0"]
        }
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
