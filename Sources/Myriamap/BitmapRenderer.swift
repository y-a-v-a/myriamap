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
    public static func image(_ scene: MapScene, width: Int = 2400) throws -> CGImage {
        let m = CanvasMapping(bounds: scene.bounds, width: Double(width))
        let height = Int(m.height)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw BitmapRendererError.contextCreationFailed }
        // Draw with a top-left origin like the SVG output.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(scene, in: ctx, mapping: m)
        guard let image = ctx.makeImage() else { throw BitmapRendererError.contextCreationFailed }
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

    /// Draws into a context whose user space has a top-left origin and the
    /// given mapping's pixel units.
    public static func draw(_ scene: MapScene, in ctx: CGContext, mapping m: CanvasMapping) {
        ctx.setFillColor(cgColor(scene.background))
        ctx.fill(CGRect(x: 0, y: 0, width: m.width, height: m.height))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for path in scene.paths where !path.subpaths.isEmpty {
            let p = CGMutablePath()
            for sub in path.subpaths where sub.count >= 2 {
                p.addLines(between: sub.map { let q = m.apply($0); return CGPoint(x: q.x, y: q.y) })
                if path.closed { p.closeSubpath() }
            }
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
