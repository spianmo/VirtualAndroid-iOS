import CoreGraphics
import Foundation
import IOSurface
import UIKit

/// Toggles the stub exposes so every host bridge can be exercised through the
/// same C callbacks (VaHostCallbacks) the real engine will call.
struct StubDiagnosticsState: Equatable {
    var gnss = false
    var camera = false
    var mic = false
    var tone = false
    var allSensors = false
}

protocol StubDiagnostics: AnyObject {
    var diagnostics: StubDiagnosticsState { get }
    func setDiagnostics(_ state: StubDiagnosticsState)
    func diagnosticVibrate()
    func diagnosticGuestCopy()
}

/// Stand-in engine used until the QEMU/gfx frameworks exist: renders an
/// animated test pattern into IOSurfaces at 60 Hz, simulates the boot
/// sequence, echoes touches/keys and shows what the host bridges deliver.
final class StubEngine: VMEngine, StubDiagnostics {
    let displayName = "Stub"
    weak var delegate: EngineDelegate?

    /// Snapshot identity of the stub (its "state.bin" is a small JSON file).
    static func snapshotIdentity(config: VMLaunchConfig) -> SnapshotIdentity {
        let app = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return SnapshotIdentity(engine: "stub-v1-\(app)", gfx: "none", image: "stub",
                                argvHash: SnapshotHash.sha256(strings: ["\(config.displayWidth)x\(config.displayHeight)",
                                                                        "\(config.displayDPI)", "\(config.memoryMB)"]))
    }

    private struct SavedState: Codable {
        var elapsed: Double
        var frameNumber: UInt64
        var bootCompleted: Bool
        var volume: Int
        var screenOn: Bool
        var keyLog: [String]
    }
    private var pausedAt: Double?

    private let queue = DispatchQueue(label: "va.stub", qos: .userInteractive)
    private var cb = VaHostCallbacks()
    private weak var frames: FrameSink?
    private var timer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?

    private var width = 1080
    private var height = 2340
    private var surfaces: [IOSurfaceRef] = []
    private var surfaceIndex = 0
    private var frameNumber: UInt64 = 0
    private var startTime = CACurrentMediaTime()
    private var bootDuration: Double = 5.0
    private var bootCompleted = false
    private var shuttingDownAt: Double?
    private var paused = false
    private var screenOn = true
    private var fps: Double = 0
    private var lastFpsTime = CACurrentMediaTime()
    private var lastFpsFrame: UInt64 = 0

    // Echoed input/bridge data.
    private var touches: [Int32: VaTouchPoint] = [:]
    private var touchEvents: UInt64 = 0
    private var keyLog: [String] = []
    private var sensorValues: [UInt32: [Float]] = [:]
    private var lastAccelTime: Double = 0
    private var explicitRotation = 0
    private var uiRotation = 0
    private var battery: VaBatteryState?
    private var batteryKnown = false
    private var lastBatteryPoll: Double = -10
    private var location: VaLocation?
    private var hostClipboard: String?
    private var guestCopies = 0
    private var volume = 7
    private var vibrations = 0

    private var diag = StubDiagnosticsState()
    private var cameraBuffer = [UInt8]()
    private var cameraImage: CGImage?
    private let cameraSize = (320, 240)
    private var micLevel: Float = 0
    private var tonePhase: Double = 0

    private lazy var background: CGImage? = Self.makeColorBars(width: 1080, height: 300)

    private static let bootPhases: [(Double, String)] = [
        (0.00, "Linux 5.15.41-android13 (stub)"),
        (0.12, "init: mounting /system /vendor /data"),
        (0.30, "init: starting service 'zygote'"),
        (0.50, "SystemServer: Entered the Android system server"),
        (0.75, "ActivityManager: System now ready"),
        (0.92, "SurfaceFlinger: Boot is finished"),
    ]

    // MARK: Lifecycle

    func start(config: VMLaunchConfig, host: HostBridge, frames: FrameSink) throws {
        cb = host.makeCallbacks()
        self.frames = frames
        width = config.displayWidth
        height = config.displayHeight
        surfaces = (0..<3).compactMap { _ in Self.makeSurface(width: width, height: height) }
        guard surfaces.count == 3 else { throw EngineError.startFailed("IOSurfaceCreate failed") }
        startTime = CACurrentMediaTime()
        guestLog(1, "stub engine: \(width)x\(height)@\(config.displayDPI)dpi, \(config.memoryMB) MB, \(config.cpuCount) vCPU")
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        if let stateFile = config.restoreStateFile {
            // Restore: load, stay paused until resume() (like QEMU -incoming + -S).
            paused = true
            pausedAt = CACurrentMediaTime()
            queue.asyncAfter(deadline: .now() + 0.15) { [self] in
                do {
                    let s = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateFile))
                    startTime = pausedAt! - s.elapsed
                    frameNumber = s.frameNumber
                    bootCompleted = s.bootCompleted
                    volume = s.volume
                    screenOn = s.screenOn
                    keyLog = s.keyLog
                    lastFpsFrame = s.frameNumber
                    lastFpsTime = CACurrentMediaTime()
                    if bootCompleted {
                        // What the engine's services must do after a load: re-apply the
                        // host-side requests (sensors, GNSS, audio...) in this new process.
                        cb.sensor_set_enabled?(cb.opaque, VA_SENSOR_ACCELERATION, true, 66)
                    }
                    guestLog(1, "stub: restored state (t=\(String(format: "%.1f", s.elapsed)) s, frame \(s.frameNumber))")
                    DispatchQueue.main.async { self.delegate?.engine(self, restoreFinished: .success(())) }
                } catch {
                    DispatchQueue.main.async { self.delegate?.engine(self, restoreFinished: .failure(error)) }
                }
            }
        } else {
            setGuestState(VA_GUEST_BOOTING)
            t.resume()
        }
    }

    func suspend(stateFile: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let t0 = CACurrentMediaTime()
            if !paused, timer != nil {
                paused = true
                pausedAt = t0
                timer?.suspend()
            }
            let s = SavedState(elapsed: (pausedAt ?? t0) - startTime, frameNumber: frameNumber,
                               bootCompleted: bootCompleted, volume: volume, screenOn: screenOn, keyLog: keyLog)
            let result: Result<Void, Error> = Result {
                try JSONEncoder().encode(s).write(to: stateFile)
                // Stand-in for the file-backed guest RAM, so the snapshot layout
                // (and its validity check) is the same as with QEMU.
                let ram = stateFile.deletingLastPathComponent().appendingPathComponent("ram.img")
                if !FileManager.default.fileExists(atPath: ram.path) {
                    try Data(count: 4096).write(to: ram)
                }
            }
            guestLog(1, String(format: "stub: suspended in %.0f ms", (CACurrentMediaTime() - t0) * 1000))
            DispatchQueue.main.async { completion(result) }
        }
    }

    func pause() {
        queue.async { [self] in
            guard !paused, timer != nil else { return }
            paused = true
            pausedAt = CACurrentMediaTime()
            timer?.suspend()
            setGuestState(VA_GUEST_PAUSED)
        }
    }

    func resume() {
        queue.async { [self] in
            guard paused else { return }
            paused = false
            if let p = pausedAt { startTime += CACurrentMediaTime() - p }   // guest time froze while paused
            pausedAt = nil
            timer?.resume()
            setGuestState(bootCompleted ? VA_GUEST_BOOT_COMPLETED : VA_GUEST_BOOTING)
        }
    }

    func requestShutdown() {
        queue.async { [self] in
            if paused { paused = false; timer?.resume() }
            shuttingDownAt = CACurrentMediaTime()
            guestLog(1, "stub: power off requested")
        }
    }

    func forceStop() {
        queue.async { [self] in finish(status: 0) }
    }

    private func finish(status: Int32) {
        guard timer != nil else { return }
        if paused { timer?.resume() }
        timer?.cancel()
        timer = nil
        setDiagnosticsLocked(StubDiagnosticsState())
        cb.sensor_set_enabled?(cb.opaque, VA_SENSOR_ACCELERATION, false, 0)
        setGuestState(VA_GUEST_SHUTDOWN)
        DispatchQueue.main.async { self.delegate?.engine(self, didExitWithStatus: status, fatal: false, message: nil) }
    }

    private func setGuestState(_ s: VaGuestState) {
        cb.guest_state_changed?(cb.opaque, s)
        DispatchQueue.main.async { self.delegate?.engine(self, guestStateChanged: s) }
    }

    private func guestLog(_ level: Int32, _ msg: String) {
        msg.withCString { cb.log?(cb.opaque, level, $0) }
        DispatchQueue.main.async { self.delegate?.engine(self, log: level, message: msg) }
    }

    // MARK: EngineInput (any thread)

    func touch(_ points: [VaTouchPoint]) {
        queue.async { [self] in
            touchEvents += 1
            for p in points {
                if p.down { touches[p.slot] = p } else { touches.removeValue(forKey: p.slot) }
            }
        }
    }

    func key(_ linuxKeycode: UInt32, down: Bool) {
        queue.async { [self] in
            keyLog.append("\(LinuxKeymap.name(linuxKeycode))\(down ? "↓" : "↑")")
            if keyLog.count > 8 { keyLog.removeFirst(keyLog.count - 8) }
            guard down else { return }
            switch linuxKeycode {
            case LinuxKeymap.power: screenOn.toggle()
            case LinuxKeymap.volumeUp: volume = min(15, volume + 1)
            case LinuxKeymap.volumeDown: volume = max(0, volume - 1)
            default: if !screenOn { screenOn = true }
            }
        }
    }

    func sensorEvent(_ type: VaSensorType, values: [Float], timestampNs: Int64) {
        queue.async { [self] in
            sensorValues[type.rawValue] = values
            if type == VA_SENSOR_ACCELERATION { lastAccelTime = CACurrentMediaTime() }
        }
    }

    func locationUpdate(_ location: VaLocation) {
        queue.async { [self] in self.location = location }
    }

    func batteryChanged() {
        queue.async { [self] in lastBatteryPoll = -10 }   // re-poll on next frame
    }

    func clipboardFromHost(_ text: String) {
        queue.async { [self] in hostClipboard = text }
    }

    func setDisplayRotation(_ degrees: Int) {
        queue.async { [self] in explicitRotation = degrees }
    }

    // MARK: StubDiagnostics

    var diagnostics: StubDiagnosticsState { queue.sync { diag } }

    func setDiagnostics(_ state: StubDiagnosticsState) {
        queue.async { [self] in setDiagnosticsLocked(state) }
    }

    func diagnosticVibrate() {
        queue.async { [self] in
            vibrations += 1
            cb.vibrate?(cb.opaque, 300)
        }
    }

    func diagnosticGuestCopy() {
        queue.async { [self] in
            guestCopies += 1
            let text = "Copied inside the Android stub #\(guestCopies)"
            let bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                    cb.clipboard_from_guest?(cb.opaque, $0, buf.count)
                }
            }
        }
    }

    private func setDiagnosticsLocked(_ new: StubDiagnosticsState) {
        let old = diag
        diag = new
        let o = cb.opaque
        if new.gnss != old.gnss { cb.location_set_enabled?(o, new.gnss) }
        if new.camera != old.camera {
            if new.camera {
                let count = cb.camera_count?(o) ?? 0
                var info = VaCameraInfo()
                if count > 0, cb.camera_info?(o, 0, &info) == true {
                    let name = withUnsafeBytes(of: info.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    guestLog(1, "stub: camera 0 '\(name)' facing=\(info.facing.rawValue) orientation=\(info.orientation_deg)")
                }
                if count == 0 || cb.camera_start?(o, 0, Int32(cameraSize.0), Int32(cameraSize.1)) != true {
                    diag.camera = false
                    guestLog(2, "stub: camera unavailable")
                }
            } else {
                cb.camera_stop?(o, 0)
                cameraImage = nil
            }
        }
        if new.mic != old.mic {
            if new.mic { _ = cb.mic_start?(o, 16000, 1) } else { cb.mic_stop?(o); micLevel = 0 }
        }
        if new.tone != old.tone {
            if new.tone { startTone() } else { stopTone() }
        }
        if new.allSensors != old.allSensors {
            let mask = cb.sensor_available_mask?(o) ?? 0
            for raw in 0..<VA_SENSOR_COUNT.rawValue where mask & (1 << raw) != 0 {
                let t = VaSensorType(rawValue: raw)
                if t == VA_SENSOR_ACCELERATION && bootCompleted { continue }   // keep the orientation listener on
                cb.sensor_set_enabled?(o, t, new.allSensors, 50)
            }
        }
    }

    private func startTone() {
        guard cb.speaker_start?(cb.opaque, 48000, 2) == true else { diag.tone = false; return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        var last: Double?
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Prime 100 ms, then produce exactly what elapsed (timers coalesce).
            let now = CACurrentMediaTime()
            let frames = last.map { Int(((now - $0) * 48000).rounded()) } ?? 4800
            last = now
            if frames > 0 { self.writeTone(frames: min(frames, 9600)) }
        }
        t.resume()
        audioTimer = t
    }

    private func stopTone() {
        audioTimer?.cancel()
        audioTimer = nil
        cb.speaker_stop?(cb.opaque)
    }

    private func writeTone(frames: Int) {
        var samples = [Int16](repeating: 0, count: frames * 2)
        let step = 2 * Double.pi * 440 / 48000
        for i in 0..<frames {
            let v = Int16(sin(tonePhase) * 6000)
            samples[i * 2] = v
            samples[i * 2 + 1] = v
            tonePhase += step
        }
        tonePhase = tonePhase.truncatingRemainder(dividingBy: 2 * .pi)
        _ = samples.withUnsafeBufferPointer { cb.speaker_write?(cb.opaque, $0.baseAddress!, frames) }
    }

    // MARK: Frame loop (queue)

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = now - startTime

        if let t = shuttingDownAt, now - t > 1.2 {
            finish(status: 0)
            return
        }
        if !bootCompleted, elapsed >= bootDuration {
            bootCompleted = true
            setGuestState(VA_GUEST_BOOT_COMPLETED)
            // Like Android's WindowOrientationListener (SENSOR_DELAY_UI).
            cb.sensor_set_enabled?(cb.opaque, VA_SENSOR_ACCELERATION, true, 66)
            guestLog(1, "stub: sys.boot_completed=1 after \(String(format: "%.1f", elapsed)) s")
        } else if !bootCompleted {
            let f = min(1, elapsed / bootDuration)
            let phase = Self.bootPhases.last(where: { $0.0 <= f })?.1 ?? ""
            DispatchQueue.main.async { self.delegate?.engine(self, bootProgress: f, message: phase) }
        }
        if now - lastBatteryPoll > 2 {
            lastBatteryPoll = now
            var b = VaBatteryState()
            batteryKnown = cb.battery_get?(cb.opaque, &b) ?? false
            battery = batteryKnown ? b : nil
        }
        pollDiagnostics()
        updateRotation(now: now)

        frameNumber += 1
        if now - lastFpsTime >= 1 {
            fps = Double(frameNumber - lastFpsFrame) / (now - lastFpsTime)
            lastFpsTime = now
            lastFpsFrame = frameNumber
        }

        let surface = surfaces[surfaceIndex]
        surfaceIndex = (surfaceIndex + 1) % surfaces.count
        render(into: surface, time: elapsed)
        frames?.present(DisplayFrame(surface: surface, width: width, height: height, rotationDegrees: 0,
                                     number: frameNumber))
    }

    private func pollDiagnostics() {
        let o = cb.opaque
        if diag.camera {
            let (w, h) = cameraSize
            if cameraBuffer.count != w * h * 3 / 2 { cameraBuffer = [UInt8](repeating: 0, count: w * h * 3 / 2) }
            var ts: Int64 = 0
            let ok = cameraBuffer.withUnsafeMutableBufferPointer {
                cb.camera_read_frame?(o, 0, $0.baseAddress!, $0.count, &ts) ?? false
            }
            if ok { cameraImage = Self.grayImage(cameraBuffer, width: w, height: h) }
        }
        if diag.mic {
            var buf = [Int16](repeating: 0, count: 1600)
            let n = buf.withUnsafeMutableBufferPointer { cb.mic_read?(o, $0.baseAddress!, $0.count) ?? 0 }
            if n > 0 {
                var sum: Float = 0
                for i in 0..<n { let s = Float(buf[i]) / 32768; sum += s * s }
                micLevel = max(micLevel * 0.85, sqrt(sum / Float(n)))
            } else {
                micLevel *= 0.9
            }
        }
    }

    /// Like Android auto-rotate: follow gravity when accelerometer data
    /// arrives, otherwise the rotation the app reported.
    private func updateRotation(now: Double) {
        guard now - lastAccelTime < 1, let a = sensorValues[VA_SENSOR_ACCELERATION.rawValue], a.count >= 2 else {
            uiRotation = explicitRotation
            return
        }
        let x = a[0], y = a[1]
        guard sqrt(x * x + y * y) > 0.5 * MotionBridge.standardGravity else { return }   // lying flat: keep
        if abs(y) >= abs(x) { uiRotation = y >= 0 ? 0 : 180 } else { uiRotation = x > 0 ? 90 : 270 }
    }

    // MARK: Drawing

    private static func makeSurface(width: Int, height: Int) -> IOSurfaceRef? {
        let bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let props: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bpr,
            kIOSurfaceAllocSize: bpr * height,
            kIOSurfacePixelFormat: 0x4247_5241,      // 'BGRA'
        ]
        return IOSurfaceCreate(props as CFDictionary)
    }

    private static func makeColorBars(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                      CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75),
                                                     (0, 0.75, 0), (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75)]
        let barW = CGFloat(width) / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * barW, y: CGFloat(height) * 0.3, width: barW + 1, height: CGFloat(height) * 0.7))
        }
        // Grayscale ramp underneath (bottom in CG coordinates).
        let steps = 16
        for i in 0..<steps {
            let v = CGFloat(i) / CGFloat(steps - 1)
            ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * CGFloat(width) / CGFloat(steps), y: 0,
                            width: CGFloat(width) / CGFloat(steps) + 1, height: CGFloat(height) * 0.3))
        }
        return ctx.makeImage()
    }

    private static func grayImage(_ nv21: [UInt8], width: Int, height: Int) -> CGImage? {
        let y = Data(nv21.prefix(width * height))
        guard let provider = CGDataProvider(data: y as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func render(into surface: IOSurfaceRef, time t: Double) {
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        guard let ctx = CGContext(data: IOSurfaceGetBaseAddress(surface), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: IOSurfaceGetBytesPerRow(surface),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                      CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        // Top-left origin, y down (UIKit drawing conventions).
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let W = CGFloat(width), H = CGFloat(height)
        guard screenOn else {
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            drawText("screen off (POWER)", at: CGPoint(x: W / 2, y: H / 2), size: 34, color: .darkGray, center: true)
            return
        }

        // Logical canvas rotated the way Android would render for uiRotation.
        ctx.saveGState()
        let logical: CGSize
        switch uiRotation {
        case 90:
            ctx.translateBy(x: W, y: 0); ctx.rotate(by: .pi / 2); logical = CGSize(width: H, height: W)
        case 180:
            ctx.translateBy(x: W, y: H); ctx.rotate(by: .pi); logical = CGSize(width: W, height: H)
        case 270:
            ctx.translateBy(x: 0, y: H); ctx.rotate(by: -.pi / 2); logical = CGSize(width: H, height: W)
        default:
            logical = CGSize(width: W, height: H)
        }
        drawScene(ctx, size: logical, time: t)
        ctx.restoreGState()

        // Touch echo in raw panel coordinates (exactly under the finger).
        for (slot, p) in touches.sorted(by: { $0.key < $1.key }) {
            let c = CGPoint(x: CGFloat(p.x) * W, y: CGFloat(p.y) * H)
            let hue = CGFloat(slot) / 10
            ctx.setFillColor(UIColor(hue: hue, saturation: 0.8, brightness: 1, alpha: 0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 90, y: c.y - 90, width: 180, height: 180))
            ctx.setStrokeColor(UIColor(hue: hue, saturation: 0.8, brightness: 1, alpha: 1).cgColor)
            ctx.setLineWidth(6)
            ctx.strokeEllipse(in: CGRect(x: c.x - 90, y: c.y - 90, width: 180, height: 180))
            drawText("\(slot)", at: CGPoint(x: c.x, y: c.y - 30), size: 48, color: .white, center: true)
        }
        if let s = shuttingDownAt {
            let alpha = min(1, (CACurrentMediaTime() - s) / 1.0)
            ctx.setFillColor(UIColor(white: 0, alpha: alpha).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            drawText("Shutting down…", at: CGPoint(x: W / 2, y: H / 2), size: 54, color: .white, center: true)
        }
    }

    private func drawScene(_ ctx: CGContext, size: CGSize, time t: Double) {
        let W = size.width, H = size.height
        // Slowly shifting gradient background.
        let hue = CGFloat((t / 20).truncatingRemainder(dividingBy: 1))
        let top = UIColor(hue: hue, saturation: 0.55, brightness: 0.35, alpha: 1)
        let bottom = UIColor(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.12, alpha: 1)
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: H), options: [])
        }

        // Status bar.
        ctx.setFillColor(UIColor(white: 0, alpha: 0.35).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: 110))
        drawText("VirtualAndroid · stub engine", at: CGPoint(x: 40, y: 34), size: 38, color: .white)
        let clock = Self.clockFormatter.string(from: Date())
        let batt = battery.map { "\($0.capacity_percent)%\($0.charging ? "⚡︎" : "")" } ?? "AC"
        drawText("\(batt)  \(clock)", at: CGPoint(x: W - 40, y: 34), size: 38, color: .white, right: true)

        // Color bars + ramp.
        if let bars = background {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: 110 + 300)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(bars, in: CGRect(x: 0, y: 0, width: W, height: 300))
            ctx.restoreGState()
        }

        // Sweeping bar + bouncing ball: motion / frame pacing check.
        let sweepX = CGFloat((t * 0.5).truncatingRemainder(dividingBy: 1)) * W
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: sweepX - 6, y: 110, width: 12, height: 300))
        let ballY = 470 + CGFloat(abs(sin(t * 2.2))) * 140
        let ballX = W / 2 + CGFloat(sin(t * 0.9)) * (W / 2 - 80)
        ctx.setFillColor(UIColor.systemYellow.cgColor)
        ctx.fillEllipse(in: CGRect(x: ballX - 40, y: ballY - 40, width: 80, height: 80))

        drawText(String(format: "frame %llu   %.0f fps   rot %d°", frameNumber, fps, uiRotation),
                 at: CGPoint(x: 40, y: 650), size: 36, color: .white, mono: true)

        var y: CGFloat = 730
        if !bootCompleted {
            let f = min(1, t / bootDuration)
            drawText("android", at: CGPoint(x: W / 2, y: H * 0.42), size: 120, color: UIColor(white: 1, alpha: 0.6 + 0.4 * CGFloat(sin(t * 4))), center: true)
            let barRect = CGRect(x: W * 0.15, y: H * 0.42 + 190, width: W * 0.7, height: 16)
            ctx.setFillColor(UIColor(white: 1, alpha: 0.2).cgColor)
            ctx.fill(barRect)
            ctx.setFillColor(UIColor.systemGreen.cgColor)
            ctx.fill(CGRect(x: barRect.minX, y: barRect.minY, width: barRect.width * CGFloat(f), height: barRect.height))
            let phase = Self.bootPhases.last(where: { $0.0 <= f })?.1 ?? ""
            drawText(phase, at: CGPoint(x: W / 2, y: barRect.maxY + 40), size: 32, color: .white, center: true, mono: true)
            return
        }

        // "Home screen": app icon grid.
        let cols = W > H ? 8 : 4
        let rows = W > H ? 1 : 2
        let cell = (W - 80) / CGFloat(cols)
        let names = ["Phone", "Messages", "Chrome", "Camera", "Settings", "Files", "Maps", "Clock"]
        for i in 0..<(cols * rows) where i < names.count {
            let cx = 40 + CGFloat(i % cols) * cell + cell / 2
            let cy = y + CGFloat(i / cols) * (cell + 40) + cell / 2
            let r = cell * 0.36
            ctx.setFillColor(UIColor(hue: CGFloat(i) / 8, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), cornerRadius: r * 0.5).cgPath)
            ctx.fillPath()
            drawText(names[i], at: CGPoint(x: cx, y: cy + r + 12), size: 28, color: .white, center: true)
        }
        y += CGFloat(rows) * (cell + 40) + 30

        // Info panel: what the host bridges deliver.
        func line(_ s: String) {
            drawText(s, at: CGPoint(x: 40, y: y), size: 30, color: UIColor(white: 0.92, alpha: 1), mono: true)
            y += 44
        }
        let fmt = { (v: [Float]?) -> String in
            guard let v else { return "—" }
            return v.map { String(format: "%7.2f", $0) }.joined(separator: " ")
        }
        line("touch: \(touches.count) down, \(touchEvents) events")
        line("keys:  \(keyLog.suffix(6).joined(separator: " "))")
        line("accel: \(fmt(sensorValues[VA_SENSOR_ACCELERATION.rawValue])) m/s²")
        if diag.allSensors {
            line("gyro:  \(fmt(sensorValues[VA_SENSOR_GYROSCOPE.rawValue])) rad/s")
            line("mag:   \(fmt(sensorValues[VA_SENSOR_MAGNETIC_FIELD.rawValue])) µT")
            line("grav:  \(fmt(sensorValues[VA_SENSOR_GRAVITY.rawValue]))")
            line("rot:   \(fmt(sensorValues[VA_SENSOR_ROTATION_VECTOR.rawValue]))")
            line("press: \(fmt(sensorValues[VA_SENSOR_PRESSURE.rawValue])) hPa")
        }
        if let b = battery {
            line("battery: \(b.capacity_percent)% ac=\(b.ac_online) chg=\(b.charging) \(b.temperature_decic / 10)°C")
        } else {
            line("battery: unknown (AC 100%)")
        }
        if let l = location {
            line(String(format: "gnss:  %.5f, %.5f ±%.0fm", l.latitude_deg, l.longitude_deg, l.horizontal_accuracy_m))
        } else if diag.gnss {
            line("gnss:  waiting for fix…")
        }
        line("volume: \(String(repeating: "▮", count: volume))\(String(repeating: "▯", count: 15 - volume))")
        if let c = hostClipboard { line("clip from iOS: \(c.prefix(28))") }
        if diag.mic {
            line("mic:   " + String(repeating: "█", count: Int(min(1, micLevel * 8) * 24)))
        }
        if diag.tone { line("speaker: 440 Hz tone") }
        if let img = cameraImage {
            let w: CGFloat = 480, h: CGFloat = 360
            let rect = CGRect(x: 40, y: y + 10, width: w, height: h)
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
            drawText("camera 0 (Y plane)", at: CGPoint(x: rect.maxX + 20, y: rect.minY), size: 26, color: .white)
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func drawText(_ s: String, at p: CGPoint, size: CGFloat, color: UIColor, center: Bool = false,
                          right: Bool = false, mono: Bool = false) {
        let font = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
                        : UIFont.systemFont(ofSize: size, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = s as NSString
        let sz = str.size(withAttributes: attrs)
        var origin = p
        if center { origin.x -= sz.width / 2 }
        if right { origin.x -= sz.width }
        str.draw(at: origin, withAttributes: attrs)
    }
}
