import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers

/// last-frame.png <-> IOSurface (BGRA, row 0 = top), for the M4 "show the
/// last frame immediately" path.
enum FrameImage {
    private static let bgraInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func cgImage(from surface: IOSurfaceRef) -> CGImage? {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        let bpr = IOSurfaceGetBytesPerRow(surface)
        guard w > 0, h > 0,
              let ctx = CGContext(data: IOSurfaceGetBaseAddress(surface), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: bgraInfo) else { return nil }
        return ctx.makeImage()      // copies, so the surface can be unlocked/recycled
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return false }
        _ = try? FileManager.default.removeItem(at: url)
        return (try? FileManager.default.moveItem(at: tmp, to: url)) != nil
    }

    static func surface(fromPNG url: URL) -> IOSurfaceRef? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        let bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4)
        let props: [CFString: Any] = [
            kIOSurfaceWidth: w, kIOSurfaceHeight: h, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bpr, kIOSurfaceAllocSize: bpr * h,
            kIOSurfacePixelFormat: 0x4247_5241,      // 'BGRA'
        ]
        guard let surface = IOSurfaceCreate(props as CFDictionary) else { return nil }
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        guard let ctx = CGContext(data: IOSurfaceGetBaseAddress(surface), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: bgraInfo) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return surface
    }
}
