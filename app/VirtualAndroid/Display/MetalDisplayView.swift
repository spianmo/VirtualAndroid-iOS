import IOSurface
import Metal
import QuartzCore
import UIKit

/// How the guest panel follows the iOS interface orientation.
enum DisplayRotationMode: String, CaseIterable, Identifiable {
    /// The guest panel stays fixed to the physical screen (like a real phone):
    /// in landscape the frame is counter-rotated and Android rotates its own UI.
    case followDevice
    /// Always draw the frame upright in the current interface orientation.
    case upright
    var id: String { rawValue }
    var label: String { self == .followDevice ? "Panel fixed to device" : "Always upright" }
}

/// CAMetalLayer-backed view showing guest frames (IOSurfaces), letterboxed at
/// the guest's aspect ratio. Also the multi-touch and hardware-keyboard source.
final class MetalDisplayView: UIView, FrameSink {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var input: EngineInput? {
        get { inputEnabled ? inputTarget : nil }
        set { inputTarget = newValue }
    }
    private weak var inputTarget: EngineInput?
    /// Closed while the guest is stopped (pause/suspend/restore).
    var inputEnabled = true
    var rotationMode: DisplayRotationMode = .followDevice { didSet { setNeedsLayout() } }
    /// Called (main thread) with the Android surface rotation when the
    /// interface orientation changes.
    var onAndroidRotationChange: ((Int) -> Void)?
    var onUserInteraction: (() -> Void)?

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var displayLink: CADisplayLink?

    private let frameLock = NSLock()
    private var pendingFrame: DisplayFrame?
    private var currentFrame: DisplayFrame?
    private var needsRedraw = true
    private var copyTexture: MTLTexture?        // fallback when IOSurface textures are unsupported
    private var ioSurfaceTexturesWork = true

    private(set) var quarterTurns = 0
    private var androidRotation = -1
    private var contentSize = CGSize(width: 1080, height: 2340)

    // Touch slot assignment: stable 0..9 per finger while it is down.
    private var slots: [ObjectIdentifier: Int32] = [:]

    private(set) var framesDrawn: UInt64 = 0
    /// One-shot (main thread): called when the next engine frame is drawn.
    var onNextFrame: (() -> Void)?
    /// Frame number of a placeholder (last-frame.png) being shown, if any.
    private var placeholderNumber: UInt64?

    override init(frame: CGRect) {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        buildPipeline()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        displayLink?.invalidate()
    }

    func setGuestSize(width: Int, height: Int) {
        contentSize = CGSize(width: width, height: height)
        setNeedsLayout()
    }

    private func buildPipeline() {
        guard let device, let library = device.makeDefaultLibrary() else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "va_display_vertex")
        desc.fragmentFunction = library.makeFunction(name: "va_display_fragment")
        desc.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)
    }

    // MARK: FrameSink (any thread)

    func present(_ frame: DisplayFrame) {
        frameLock.lock()
        pendingFrame = frame
        frameLock.unlock()
    }

    /// Shows a still image (the snapshot's last frame) until the engine
    /// presents its first frame. Main thread.
    func showPlaceholder(_ surface: IOSurfaceRef) {
        let frame = DisplayFrame(surface: surface, width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface),
                                 rotationDegrees: 0, number: UInt64.max)
        placeholderNumber = frame.number
        present(frame)
    }

    /// The most recent frame (main thread), for saving last-frame.png.
    func latestFrame() -> DisplayFrame? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return pendingFrame ?? currentFrame
    }

    func clearFrame() {
        frameLock.lock()
        pendingFrame = nil
        frameLock.unlock()
        currentFrame = nil
        needsRedraw = true
    }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        updateRotation()
        needsRedraw = true
    }

    private func updateRotation() {
        let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        // Clockwise quarter turns that keep the panel fixed to the hardware,
        // and the matching Android surface rotation (device turned CCW).
        let (turns, android): (Int, Int)
        switch orientation {
        case .landscapeLeft: (turns, android) = (1, 270)        // device turned clockwise
        case .landscapeRight: (turns, android) = (3, 90)        // device turned counter-clockwise
        case .portraitUpsideDown: (turns, android) = (2, 180)
        default: (turns, android) = (0, 0)
        }
        quarterTurns = rotationMode == .followDevice ? turns : 0
        if android != androidRotation {
            androidRotation = android
            onAndroidRotationChange?(android)
        }
    }

    // MARK: Rendering (main thread)

    fileprivate func tick() {
        frameLock.lock()
        var engineFrame = false
        if let f = pendingFrame {
            currentFrame = f
            pendingFrame = nil
            needsRedraw = true
            engineFrame = f.number != placeholderNumber
        }
        frameLock.unlock()
        if engineFrame, let cb = onNextFrame {
            onNextFrame = nil
            cb()
        }
        guard needsRedraw else { return }
        needsRedraw = false
        draw()
    }

    private func draw() {
        guard let commandQueue, let pipeline, let sampler, bounds.width > 0,
              let drawable = metalLayer.nextDrawable(),
              let cmd = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let frame = currentFrame, let texture = texture(for: frame) {
            let turns = (quarterTurns + frame.rotationDegrees / 90) & 3
            let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let rect = DisplayGeometry.letterbox(content: CGSize(width: frame.width, height: frame.height),
                                                 in: drawableSize, quarterTurns: turns)
            enc.setViewport(MTLViewport(originX: rect.minX.rounded(), originY: rect.minY.rounded(),
                                        width: rect.width.rounded(), height: rect.height.rounded(),
                                        znear: 0, zfar: 1))
            var uvs = DisplayGeometry.cornerUVs(quarterTurns: turns)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&uvs, length: MemoryLayout<SIMD2<Float>>.stride * uvs.count, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            framesDrawn += 1
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private static func metalFormat(_ surface: IOSurfaceRef) -> MTLPixelFormat {
        switch IOSurfaceGetPixelFormat(surface) {
        case 0x5247_4241: return .rgba8Unorm        // 'RGBA'
        default: return .bgra8Unorm                 // 'BGRA' (default for gfxstream/ANGLE)
        }
    }

    private func texture(for frame: DisplayFrame) -> MTLTexture? {
        guard let device else { return nil }
        let surface = frame.surface
        let format = Self.metalFormat(surface)
        if ioSurfaceTexturesWork {
            // Wrap per draw and never cache: an IOSurface-backed texture keeps
            // the surface retained/in use, and libva_gfx only recycles
            // surfaces nobody else holds. The command buffer keeps the texture
            // alive until the GPU is done with it.
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: frame.width,
                                                                height: frame.height, mipmapped: false)
            desc.usage = .shaderRead
            if let t = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) {
                return t
            }
            ioSurfaceTexturesWork = false
            NSLog("VirtualAndroid: IOSurface-backed textures unavailable, falling back to copies")
        }
        // Fallback: copy the surface bytes into a regular texture.
        if copyTexture?.width != frame.width || copyTexture?.height != frame.height || copyTexture?.pixelFormat != format {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: frame.width,
                                                                height: frame.height, mipmapped: false)
            desc.usage = .shaderRead
            copyTexture = device.makeTexture(descriptor: desc)
        }
        guard let t = copyTexture else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        t.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0,
                  withBytes: IOSurfaceGetBaseAddress(surface), bytesPerRow: IOSurfaceGetBytesPerRow(surface))
        IOSurfaceUnlock(surface, .readOnly, nil)
        return t
    }

    // MARK: Touch

    private func contentRectInView() -> CGRect {
        let size = currentFrame.map { CGSize(width: $0.width, height: $0.height) } ?? contentSize
        return DisplayGeometry.letterbox(content: size, in: bounds.size, quarterTurns: quarterTurns)
    }

    private func guestPoint(for touch: UITouch, in rect: CGRect) -> CGPoint {
        guestPoint(viewPoint: touch.location(in: self), in: rect)
    }

    private func guestPoint(viewPoint p: CGPoint, in rect: CGRect) -> CGPoint {
        let u = min(max((p.x - rect.minX) / rect.width, 0), 1)
        let v = min(max((p.y - rect.minY) / rect.height, 0), 1)
        return DisplayGeometry.guestPoint(u: u, v: v, quarterTurns: quarterTurns)
    }

    private func sendTouches(_ changed: Set<UITouch>, event: UIEvent?, ended: Bool) {
        let rect = contentRectInView()
        guard rect.width > 0 else { return }
        var points: [VaTouchPoint] = []
        // Lifted fingers first.
        if ended {
            for t in changed {
                guard let slot = slots.removeValue(forKey: ObjectIdentifier(t)) else { continue }
                let g = guestPoint(for: t, in: rect)
                points.append(VaTouchPoint(slot: slot, down: false, x: Float(g.x), y: Float(g.y), pressure: 0))
            }
        }
        // Then every finger still down (protocol-B style full state).
        for t in event?.allTouches ?? changed {
            guard t.phase != .ended, t.phase != .cancelled, let slot = slots[ObjectIdentifier(t)] else { continue }
            let g = guestPoint(for: t, in: rect)
            let pressure: Float = t.maximumPossibleForce > 0 && t.force > 0
                ? Float(min(1, t.force / t.maximumPossibleForce)) : 1
            points.append(VaTouchPoint(slot: slot, down: true, x: Float(g.x), y: Float(g.y), pressure: pressure))
        }
        if !points.isEmpty { input?.touch(points) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onUserInteraction?()
        let rect = contentRectInView()
        for t in touches {
            guard rect.contains(t.location(in: self)) else { continue }   // ignore letterbox bars
            let used = Set(slots.values)
            guard let free = (0..<10).map(Int32.init).first(where: { !used.contains($0) }) else { continue }
            slots[ObjectIdentifier(t)] = free
        }
        sendTouches(touches, event: event, ended: false)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendTouches(touches, event: event, ended: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendTouches(touches, event: event, ended: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendTouches(touches, event: event, ended: true)
    }

    /// Developer self-test: fingers at view points (in this view's
    /// coordinates) through the same view->guest mapping as real touches.
    func injectTestTouches(_ viewPoints: [CGPoint], down: Bool) {
        let rect = contentRectInView()
        guard rect.width > 0 else { return }
        let points = viewPoints.enumerated().map { i, p -> VaTouchPoint in
            let g = guestPoint(viewPoint: p, in: rect)
            return VaTouchPoint(slot: Int32(i), down: down, x: Float(g.x), y: Float(g.y), pressure: down ? 1 : 0)
        }
        input?.touch(points)
    }

    /// View point for a guest panel point (0..1), for scripted taps.
    func viewPoint(forGuest g: CGPoint) -> CGPoint {
        let rect = contentRectInView()
        let c = DisplayGeometry.contentPoint(guest: g, quarterTurns: quarterTurns)
        return CGPoint(x: rect.minX + c.x * rect.width, y: rect.minY + c.y * rect.height)
    }

    // MARK: Hardware keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, let code = LinuxKeymap.keycode(forHIDUsage: key.keyCode.rawValue) {
                input?.key(code, down: true)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        handleRelease(presses, event: event, cancelled: false)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        handleRelease(presses, event: event, cancelled: true)
    }

    private func handleRelease(_ presses: Set<UIPress>, event: UIPressesEvent?, cancelled: Bool) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, let code = LinuxKeymap.keycode(forHIDUsage: key.keyCode.rawValue) {
                input?.key(code, down: false)
            } else {
                unhandled.insert(press)
            }
        }
        guard !unhandled.isEmpty else { return }
        if cancelled { super.pressesCancelled(unhandled, with: event) } else { super.pressesEnded(unhandled, with: event) }
    }
}

/// Breaks the CADisplayLink -> target retain cycle.
private final class DisplayLinkProxy: NSObject {
    weak var view: MetalDisplayView?
    init(_ view: MetalDisplayView) { self.view = view }
    @objc func tick() { view?.tick() }
}
