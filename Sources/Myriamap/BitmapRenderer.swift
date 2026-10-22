#if canImport(CoreGraphics)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MyriaGeometry

public enum BitmapRendererError: Error {
    case contextCreationFailed
    case encodingFailed
}

/// Renders a scene with Core Graphics (PNG export, previews).
public enum BitmapRenderer {
    /// Large images are drawn as horizontal bands in parallel, each into
    /// its own rows of one bitmap. The band count is fixed, so the output
    /// doesn't depend on the machine.
    public static func image(_ scene: MapScene, width: Int = 2400) throws -> CGImage {
        let m = CanvasMapping(bounds: scene.bounds, width: Double(width))
        let height = Int(m.height)
        let bands = width * height >= 1 << 20 ? 8 : 1
        let bytesPerRow = width * 4
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { throw BitmapRendererError.contextCreationFailed }
        // Immutable paths, read by every band.
        nonisolated(unsafe) let paths = cgPaths(scene, mapping: m)
        nonisolated(unsafe) let rows = data
        let made = parallelMap(bands) { b -> Bool in
            let top = height * b / bands, bottom = height * (b + 1) / bands
            guard let band = CGContext(data: rows + top * bytesPerRow, width: width, height: bottom - top,
                                       bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // Draw with a top-left origin like the SVG output.
            band.translateBy(x: 0, y: CGFloat(bottom))
            band.scaleBy(x: 1, y: -1)
            draw(scene, paths: paths, in: band, mapping: m)
            return true
        }
        guard !made.contains(false), let image = ctx.makeImage() else { throw BitmapRendererError.contextCreationFailed }
        return image
    }

    public static func png(_ scene: MapScene, width: Int = 2400) throws -> Data {
        let image = try image(scene, width: width)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw BitmapRendererError.encodingFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw BitmapRendererError.encodingFailed }
        return data as Data
    }

    /// Encodes scenes as a looping animated GIF. Frames are rasterised in
    /// parallel and encoded in order.
    /// - Parameter delays: seconds each frame is shown.
    public static func gif(_ scenes: [MapScene], delays: [Double], width: Int) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, scenes.count, nil) else {
            throw BitmapRendererError.encodingFailed
        }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, loop)
        let images = parallelMap(scenes.count) { i in Result { try image(scenes[i], width: width) } }
        for (image, delay) in zip(images, delays) {
            let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(dest, try image.get(), frame)
        }
        guard CGImageDestinationFinalize(dest) else { throw BitmapRendererError.encodingFailed }
        return data as Data
    }

    /// Draws into a context whose user space has a top-left origin and the
    /// given mapping's pixel units.
    public static func draw(_ scene: MapScene, in ctx: CGContext, mapping m: CanvasMapping) {
        draw(scene, paths: cgPaths(scene, mapping: m), in: ctx, mapping: m)
    }

    /// The scene's paths in the mapping's pixel units, one per scene path.
    static func cgPaths(_ scene: MapScene, mapping m: CanvasMapping) -> [CGPath] {
        scene.paths.map { path in
            let p = CGMutablePath()
            for sub in path.subpaths where sub.count >= 2 {
                p.addLines(between: sub.map { let q = m.apply($0); return CGPoint(x: q.x, y: q.y) })
                if path.closed { p.closeSubpath() }
            }
            return p.copy() ?? p
        }
    }

    static func draw(_ scene: MapScene, paths: [CGPath], in ctx: CGContext, mapping m: CanvasMapping) {
        ctx.setFillColor(cgColor(scene.background))
        ctx.fill(CGRect(x: 0, y: 0, width: m.width, height: m.height))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for (path, p) in zip(scene.paths, paths) where !path.subpaths.isEmpty {
            if let fill = path.fill {
                ctx.addPath(p)
                ctx.setFillColor(cgColor(fill))
                ctx.fillPath(using: .winding)
            }
            if let stroke = path.stroke {
                ctx.addPath(p)
                ctx.setStrokeColor(cgColor(stroke))
                ctx.setLineWidth(path.lineWidth)
                ctx.strokePath()
            }
        }
        for text in scene.texts {
            let q = m.apply(text.position)
            let size = text.size * m.scale
            let font = CTFontCreateUIFontForLanguage(text.weight == .bold ? .emphasizedSystem : .system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributes: [CFString: Any] = [kCTFontAttributeName: font,
                                               kCTForegroundColorAttributeName: cgColor(text.color)]
            let line = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, text.text as CFString, attributes as CFDictionary))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.saveGState()
            // Text draws upright in a y-up space; flip locally around the anchor.
            ctx.translateBy(x: q.x - bounds.width / 2, y: q.y + (CTFontGetCapHeight(font)) / 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
#endif
