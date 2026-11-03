import CoreGraphics

/// Pure geometry shared by rendering and touch mapping.
///
/// `quarterTurns` = clockwise rotation (in 90 degree steps) applied to the
/// guest panel image when it is drawn into the view.
enum DisplayGeometry {
    /// Largest rect with the content's aspect ratio centered in `bounds`.
    static func letterbox(content: CGSize, in bounds: CGSize, quarterTurns: Int) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let rotated = quarterTurns & 1 == 1 ? CGSize(width: content.height, height: content.width) : content
        let scale = min(bounds.width / rotated.width, bounds.height / rotated.height)
        let size = CGSize(width: rotated.width * scale, height: rotated.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Texture coordinates for the strip corners BL, BR, TL, TR.
    static func cornerUVs(quarterTurns: Int) -> [SIMD2<Float>] {
        // Texture corners clockwise from top-left.
        let tex: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        // Screen corners clockwise from top-left: TL=0 TR=1 BR=2 BL=3.
        // Screen corner i shows texture corner (i - k) mod 4.
        let k = quarterTurns & 3
        func uv(_ screenCorner: Int) -> SIMD2<Float> { tex[(screenCorner - k + 4) & 3] }
        return [uv(3), uv(2), uv(0), uv(1)]
    }

    /// View point (normalized to the content rect: u right, v down) -> guest
    /// panel coordinates (0..1), inverting the drawing rotation.
    static func guestPoint(u: CGFloat, v: CGFloat, quarterTurns: Int) -> CGPoint {
        switch quarterTurns & 3 {
        case 1: return CGPoint(x: v, y: 1 - u)
        case 2: return CGPoint(x: 1 - u, y: 1 - v)
        case 3: return CGPoint(x: 1 - v, y: u)
        default: return CGPoint(x: u, y: v)
        }
    }
}
