// Host-side checks for the platform-independent app logic. Run with
// app/scripts/run_pure_tests.sh (compiles with swiftc on macOS).
import CoreGraphics
import Foundation

var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if !cond() { failures += 1; print("FAIL (line \(line)): \(msg)") }
}

// MARK: BootConfig == tools/make_initrd.py
let args = CommandLine.arguments
if args.count >= 3 {
    let ramdisk = URL(fileURLWithPath: args[1])
    let python = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("va-initrd-swift")
    try BootConfig.buildInitrd(ramdisk: ramdisk, output: out, overrides: ["androidboot.qemu.skin": "1080x2340"])
    let swift = try Data(contentsOf: out)
    check(swift == python, "initrd differs from make_initrd.py (\(swift.count) vs \(python.count) bytes)")
    check(String(decoding: swift.suffix(12), as: UTF8.self) == "#BOOTCONFIG\n", "trailer magic")
    try? FileManager.default.removeItem(at: out)
}

// MARK: DisplayGeometry: corner UVs and touch mapping are inverse of each other.
for k in 0..<4 {
    let uvs = DisplayGeometry.cornerUVs(quarterTurns: k)          // BL, BR, TL, TR
    let screen: [(CGFloat, CGFloat)] = [(0, 1), (1, 1), (0, 0), (1, 0)]
    for (i, s) in screen.enumerated() {
        let g = DisplayGeometry.guestPoint(u: s.0, v: s.1, quarterTurns: k)
        check(Float(g.x) == uvs[i].x && Float(g.y) == uvs[i].y, "k=\(k) corner \(i): touch \(g) vs uv \(uvs[i])")
    }
}
let portrait = DisplayGeometry.letterbox(content: CGSize(width: 1080, height: 2340),
                                         in: CGSize(width: 402, height: 874), quarterTurns: 0)
check(abs(portrait.width / portrait.height - 1080.0 / 2340.0) < 0.001, "portrait aspect")
let landscape = DisplayGeometry.letterbox(content: CGSize(width: 1080, height: 2340),
                                          in: CGSize(width: 874, height: 402), quarterTurns: 1)
check(abs(landscape.width / landscape.height - 2340.0 / 1080.0) < 0.001, "landscape aspect")
check(abs(landscape.midX - 437) < 0.001 && abs(landscape.midY - 201) < 0.001, "landscape centered")

// MARK: argv matches tools/run-macos.sh layout.
let root = URL(fileURLWithPath: "/img")
func disk(_ n: String, _ f: String, _ ro: Bool) -> DiskImage { DiskImage(url: root.appendingPathComponent(n), format: f, readOnly: ro) }
var b = QemuArgumentBuilder(kernel: root.appendingPathComponent("kernel-ranchu"), initrd: root.appendingPathComponent("initrd"),
                            vendor: disk("vendor.img", "raw", true), encryption: disk("encryptionkey.qcow2", "qcow2", false),
                            userdata: disk("userdata.qcow2", "qcow2", false), cache: disk("cache.qcow2", "qcow2", false),
                            system: disk("system.img", "raw", true),
                            serialLog: root.appendingPathComponent("serial.log"), hvc0Log: root.appendingPathComponent("hvc0.log"),
                            logcatLog: root.appendingPathComponent("logcat.log"))
b.qmpFD = 7
b.adbHostPort = 5555
let argv = b.build()
let drives = argv.enumerated().filter { $0.element == "-drive" }.map { argv[$0.offset + 1] }
check(drives.map { $0.components(separatedBy: ",")[1] } == ["id=vendor", "id=encrypt", "id=userdata", "id=cache", "id=system"], "disk order")
check(drives[0].hasSuffix("format=raw,read-only=on") && drives[2].contains("format=qcow2"), "disk formats")
check(argv.contains("socket,id=qmp0,fd=7") && argv.contains("chardev=qmp0,mode=control"), "qmp chardev")
// ranchu (default): adb over va-vsock-pci, no slirp forward; like run-macos.sh --machine ranchu.
check(argv.contains("user,id=mynet"), "no hostfwd on ranchu")
check(argv.contains("va-vsock-pci,guest-cid=77,adb-port=5555,pipe-port=5000"), "vsock adb")
check(argv[argv.firstIndex(of: "-M")! + 1] == "ranchu", "machine ranchu (bundle gfx lookup)")
var bv = b
bv.machine = "virt"
let argvVirt = bv.build()
check(argvVirt.contains("user,id=mynet,hostfwd=tcp:127.0.0.1:5555-:5555") && !argvVirt.contains("-device") == false, "virt hostfwd")
check(!argvVirt.joined(separator: " ").contains("va-vsock-pci"), "no vsock on virt")
b.gfxLib = "/a,b/va_gfx"
check(b.build().contains("ranchu,gfx-lib=/a,,b/va_gfx"), "gfx-lib escaped")
b.graphics = false
check(b.build().contains("ranchu,gfx=off"), "gfx off")
check(QemuArgumentBuilder.escape("/a,b") == "/a,,b", "comma escape")
check(AccelMode.tcti.qemuValue == "tcg,thread=multi,tb-size=512", "tcti accel")

// MARK: Keymap spot checks (HID usage -> Linux).
check(LinuxKeymap.keycode(forHIDUsage: 0x04) == 30, "A")
check(LinuxKeymap.keycode(forHIDUsage: 0x28) == 28, "Enter")
check(LinuxKeymap.keycode(forHIDUsage: 0x29) == 1, "Esc")
check(LinuxKeymap.keycode(forHIDUsage: 0x4F) == 106, "Right")
check(LinuxKeymap.keycode(forHIDUsage: 0x52) == 103, "Up")
check(LinuxKeymap.keycode(forHIDUsage: 0xE3) == 125, "Left GUI")
check(LinuxKeymap.keycode(forHIDUsage: 0x80) == 115, "Volume up")

print(failures == 0 ? "all pure-logic checks passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
