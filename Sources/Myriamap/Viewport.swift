import Foundation
import MyriaGeometry

/// Pan and zoom of the map inside a view. Map y points north (up); view y
/// points down.
public struct Viewport: Hashable, Sendable {
    public var bounds: Rect2
    public var size: Vec2
    /// 1 shows the whole map.
    public var zoom: Double
    /// Map point shown at the view's centre.
    public var center: Vec2
    public var margin: Double

    public init(bounds: Rect2, size: Vec2, zoom: Double = 1, center: Vec2? = nil, margin: Double = 12) {
        self.bounds = bounds
        self.size = size
        self.zoom = zoom
        self.center = center ?? bounds.center
        self.margin = margin
    }

    /// View points per map unit.
    public var scale: Double {
        let fit = min((size.x - 2 * margin) / max(bounds.width, 1e-12), (size.y - 2 * margin) / max(bounds.height, 1e-12))
        return max(fit, 1e-9) * zoom
    }

    public func toView(_ p: Vec2) -> Vec2 {
        Vec2(size.x / 2 + (p.x - center.x) * scale, size.y / 2 - (p.y - center.y) * scale)
    }

    public func toMap(_ q: Vec2) -> Vec2 {
        Vec2(center.x + (q.x - size.x / 2) / scale, center.y - (q.y - size.y / 2) / scale)
    }

    /// Zooms by `factor`, keeping the map point under `anchor` (view
    /// coordinates) in place.
    public mutating func zoom(by factor: Double, around anchor: Vec2) {
        let before = toMap(anchor)
        zoom = min(max(zoom * factor, 1), 40)
        let after = toMap(anchor)
        center = center + (before - after)
        clamp()
    }

    /// Moves the map by a drag of `delta` view points.
    public mutating func pan(by delta: Vec2) {
        center = center - Vec2(delta.x / scale, -delta.y / scale)
        clamp()
    }

    /// Keeps the map centre within the map.
    public mutating func clamp() {
        center = Vec2(min(max(center.x, bounds.minX), bounds.maxX), min(max(center.y, bounds.minY), bounds.maxY))
    }
}
