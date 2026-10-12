import Foundation
import MyriaGeometry

/// Fits map coordinates into an output canvas (y pointing down).
public struct CanvasMapping: Sendable {
    public let scale: Double
    public let offset: Vec2
    public let bounds: Rect2
    public let width: Double
    public let height: Double

    public init(bounds: Rect2, width: Double, margin: Double = 16) {
        self.bounds = bounds
        self.width = width
        scale = (width - 2 * margin) / max(bounds.width, 1e-12)
        height = (bounds.height * scale + 2 * margin).rounded(.up)
        offset = Vec2(margin - bounds.minX * scale, margin + bounds.maxY * scale)
    }

    @inlinable public func apply(_ p: Vec2) -> Vec2 { Vec2(offset.x + p.x * scale, offset.y - p.y * scale) }

    @inlinable public func invert(_ q: Vec2) -> Vec2 { Vec2((q.x - offset.x) / scale, (offset.y - q.y) / scale) }
}

public enum SVGRenderer {
    public static func render(_ scene: MapScene, width: Double = 2400, title: String? = nil) -> String {
        let m = CanvasMapping(bounds: scene.bounds, width: width)
        var out = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(m.width))" height="\(Int(m.height))" \
        viewBox="0 0 \(Int(m.width)) \(Int(m.height))" font-family="system-ui, -apple-system, 'Segoe UI', sans-serif">

        """
        if let title { out += "<title>\(escape(title))</title>\n" }
        out += "<rect width=\"100%\" height=\"100%\" fill=\"\(scene.background.hex)\"/>\n"
        for path in scene.paths where !path.subpaths.isEmpty {
            var d = ""
            d.reserveCapacity(path.subpaths.count * 40)
            for sub in path.subpaths where sub.count >= 2 {
                for (i, p) in sub.enumerated() {
                    let q = m.apply(p)
                    d += (i == 0 ? "M" : "L") + number(q.x) + " " + number(q.y)
                }
                if path.closed { d += "Z" }
            }
            var attributes = "d=\"\(d)\""
            if let fill = path.fill {
                attributes += " fill=\"\(fill.hex)\""
                if fill.a < 1 { attributes += " fill-opacity=\"\(number(fill.a, digits: 3))\"" }
            } else {
                attributes += " fill=\"none\""
            }
            if let stroke = path.stroke {
                attributes += " stroke=\"\(stroke.hex)\" stroke-width=\"\(number(path.lineWidth, digits: 2))\""
                attributes += " stroke-linejoin=\"round\" stroke-linecap=\"round\""
                if stroke.a < 1 { attributes += " stroke-opacity=\"\(number(stroke.a, digits: 3))\"" }
            }
            let id = path.group.map { " data-group=\"\($0)\"" } ?? ""
            out += "<path class=\"\(path.role.rawValue)\"\(id) \(attributes)/>\n"
        }
        for text in scene.texts {
            let q = m.apply(text.position)
            let size = text.size * m.scale
            let weight = text.weight == .bold ? " font-weight=\"600\"" : ""
            out += "<text x=\"\(number(q.x))\" y=\"\(number(q.y))\" font-size=\"\(number(size))\"\(weight) "
                + "text-anchor=\"middle\" dominant-baseline=\"middle\" fill=\"\(text.color.hex)\">"
                + escape(text.text) + "</text>\n"
        }
        out += "</svg>\n"
        return out
    }

    static func number(_ v: Double, digits: Int = 1) -> String {
        // Fast path: scale to an integer and print that. It rounds like
        // "%.Nf" unless the scaled value sits on a rounding tie, where the
        // last binary digits decide; those go through String(format:).
        let factor = [1.0, 10, 100, 1000][min(max(digits, 0), 3)]
        let scaled = v * factor
        let rounded = scaled.rounded()
        if abs(scaled) < 1e12, abs(abs(scaled - rounded) - 0.5) > 1e-6, digits <= 3 {
            var n = Int(rounded)
            if n == 0 { return "0" }
            let negative = n < 0
            n = abs(n)
            let unit = Int(factor)
            var fraction = n % unit, places = digits
            while places > 0, fraction % 10 == 0 {
                fraction /= 10
                places -= 1
            }
            var s = negative ? "-" : ""
            s += String(n / unit)
            if places > 0 {
                let f = String(fraction)
                s += "." + String(repeating: "0", count: places - f.count) + f
            }
            return s
        }
        let s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            var t = s
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t == "-0" ? "0" : t
        }
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
