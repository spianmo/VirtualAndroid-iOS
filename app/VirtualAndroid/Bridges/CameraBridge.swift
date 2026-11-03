import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// AVCaptureSession -> guest camera (NV21 frames).
///
/// Frames are captured as 420f (NV12, full range) in the sensor's native
/// landscape orientation, scaled/cropped to the size the guest asked for with
/// VTPixelTransferSession, then the chroma plane is byte-swapped to NV21 (VU).
/// Sensor orientation is reported like a typical phone: back 90, front 270.
/// Without cameras (simulator) one synthetic back camera is exposed that
/// produces a moving test pattern, so the guest camera path can be tested.
/// Camera permission is requested only when the guest opens a camera.
final class CameraBridge: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Camera {
        let device: AVCaptureDevice?     // nil = synthetic
        let facing: VaCameraFacing
        let orientation: Int
        let name: String
    }

    static let supportedSizes: [(Int, Int)] = [(1920, 1080), (1280, 720), (640, 480), (352, 288), (320, 240), (176, 144)]

    private(set) lazy var cameras: [Camera] = Self.discover()
    private let sessionQueue = DispatchQueue(label: "va.camera.session")
    private let frameQueue = DispatchQueue(label: "va.camera.frames")
    private let lock = NSLock()

    private var session: AVCaptureSession?
    private var activeIndex: Int?
    private var width = 640
    private var height = 480
    private var latest = [UInt8]()
    private var latestTimestampNs: Int64 = 0
    private var frameCount: UInt64 = 0
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var synthTimer: DispatchSourceTimer?
    private var denied = false

    private static func discover() -> [Camera] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                         mediaType: .video, position: .unspecified)
        var result: [Camera] = []
        if let back = discovery.devices.first(where: { $0.position == .back }) {
            result.append(Camera(device: back, facing: VA_CAMERA_BACK, orientation: 90, name: "back"))
        }
        if let front = discovery.devices.first(where: { $0.position == .front }) {
            result.append(Camera(device: front, facing: VA_CAMERA_FRONT, orientation: 270, name: "front"))
        }
        if result.isEmpty {
            result.append(Camera(device: nil, facing: VA_CAMERA_BACK, orientation: 90, name: "synthetic"))
        }
        return result
    }

    var count: Int { cameras.count }

    func info(at index: Int) -> VaCameraInfo? {
        guard cameras.indices.contains(index) else { return nil }
        let cam = cameras[index]
        var info = VaCameraInfo()
        info.facing = cam.facing
        info.orientation_deg = Int32(cam.orientation)
        withUnsafeMutableBytes(of: &info.name) { raw in
            let bytes = Array(cam.name.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        // The remaining entries stay 0x0 (terminator).
        for (i, size) in Self.supportedSizes.prefix(Int(va_camera_info_size_count()) - 1).enumerated() {
            va_camera_info_set_size(&info, Int32(i), Int32(size.0), Int32(size.1))
        }
        return info
    }

    /// Engine thread.
    func start(index: Int, width w: Int, height h: Int) -> Bool {
        guard cameras.indices.contains(index), w > 0, h > 0, w % 2 == 0, h % 2 == 0 else { return false }
        let cam = cameras[index]
        if cam.device != nil {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .denied || status == .restricted { denied = true; return false }
        }
        lock.lock()
        activeIndex = index
        width = w
        height = h
        latest = []
        lock.unlock()
        sessionQueue.async { self.configure(cam) }
        return true
    }

    func stop(index: Int) {
        lock.lock()
        guard activeIndex == index else { lock.unlock(); return }
        activeIndex = nil
        lock.unlock()
        sessionQueue.async { self.teardown() }
    }

    func stopAll() {
        lock.lock()
        activeIndex = nil
        lock.unlock()
        sessionQueue.async { self.teardown() }
    }

    func readFrame(index: Int, into dst: UnsafeMutablePointer<UInt8>, capacity: Int,
                   timestampNs: UnsafeMutablePointer<Int64>?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeIndex == index, !latest.isEmpty, latest.count <= capacity else { return false }
        latest.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: src.count)
        }
        timestampNs?.pointee = latestTimestampNs
        return true
    }

    var status: String {
        lock.lock()
        defer { lock.unlock() }
        let names = cameras.map(\.name).joined(separator: "/")
        if let i = activeIndex {
            return "Camera: \(cameras[i].name) \(width)x\(height) frames=\(frameCount)"
        }
        return "Camera: idle [\(names)]\(denied ? " (denied)" : "")"
    }

    // MARK: Session (sessionQueue)

    private func teardown() {
        synthTimer?.cancel()
        synthTimer = nil
        session?.stopRunning()
        session = nil
        transfer = nil
        pool = nil
    }

    private func configure(_ cam: Camera) {
        teardown()
        guard let device = cam.device else {
            startSynthetic()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.sessionQueue.async {
                    if granted { self.configure(cam) } else { self.denied = true }
                }
            }
            return
        default:
            denied = true
            return
        }
        lock.lock()
        let w = width, h = height
        lock.unlock()

        let session = AVCaptureSession()
        session.beginConfiguration()
        if w <= 640 && h <= 480, session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if w <= 1280 && h <= 720, session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        var t: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
        if let t {
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Trim)
        }
        transfer = t
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p
        self.session = session
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let src = CMSampleBufferGetImageBuffer(sampleBuffer), let transfer, let pool else { return }
        var dstOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstOut)
        guard let dst = dstOut, VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr else {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        storeNV21(from: dst, timestampNs: pts.isValid ? Int64(pts.seconds * 1e9) : hostMonotonicNs())
    }

    private func storeNV21(from pb: CVPixelBuffer, timestampNs: Int64) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var out = [UInt8](repeating: 0, count: w * h * 3 / 2)
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
              let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        out.withUnsafeMutableBufferPointer { o in
            let base = o.baseAddress!
            for row in 0..<h {
                (base + row * w).update(from: y + row * yStride, count: w)
            }
            let chroma = base + w * h
            for row in 0..<(h / 2) {
                let s = uv + row * uvStride
                let d = chroma + row * w
                var i = 0
                while i < w {
                    d[i] = s[i + 1]       // V
                    d[i + 1] = s[i]       // U
                    i += 2
                }
            }
        }
        publish(out, timestampNs: timestampNs)
    }

    private func publish(_ frame: [UInt8], timestampNs: Int64) {
        lock.lock()
        if activeIndex != nil {
            latest = frame
            latestTimestampNs = timestampNs
            frameCount += 1
        }
        lock.unlock()
    }

    // MARK: Synthetic camera

    private func startSynthetic() {
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        var tick = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let w = self.width, h = self.height
            self.lock.unlock()
            tick += 1
            self.publish(Self.syntheticFrame(width: w, height: h, tick: tick), timestampNs: hostMonotonicNs())
        }
        timer.resume()
        synthTimer = timer
    }

    static func syntheticFrame(width w: Int, height h: Int, tick: Int) -> [UInt8] {
        var out = [UInt8](repeating: 128, count: w * h * 3 / 2)
        out.withUnsafeMutableBufferPointer { o in
            let p = o.baseAddress!
            for row in 0..<h {
                let line = p + row * w
                for x in 0..<w {
                    line[x] = UInt8(truncatingIfNeeded: (x + tick * 4) ^ (row / 16 * 16))
                }
            }
            // Moving colored square in the chroma plane.
            let chroma = p + w * h
            let side = max(8, w / 8)
            let cx = (tick * 3) % max(1, w / 2 - side / 2)
            let cy = h / 8
            for row in cy..<min(h / 2, cy + side / 2) {
                for col in cx..<min(w / 2, cx + side / 2) {
                    chroma[row * w + col * 2] = 240     // V
                    chroma[row * w + col * 2 + 1] = 60  // U
                }
            }
        }
        return out
    }
}
