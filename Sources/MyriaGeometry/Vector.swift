import Foundation

/// A point or direction in 3D space. Points on the unit sphere represent
/// locations on the globe.
public struct Vec3: Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let unitX = Vec3(1, 0, 0)
    public static let unitY = Vec3(0, 1, 0)
    public static let unitZ = Vec3(0, 0, 1)

    @inlinable public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    @inlinable public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    @inlinable public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    @inlinable public static func * (s: Double, a: Vec3) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    @inlinable public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    @inlinable public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    @inlinable public static func += (a: inout Vec3, b: Vec3) { a = a + b }

    @inlinable public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }

    @inlinable public func cross(_ o: Vec3) -> Vec3 {
        Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }

    @inlinable public var lengthSquared: Double { dot(self) }
    @inlinable public var length: Double { lengthSquared.squareRoot() }

    @inlinable public var normalized: Vec3 {
        let l = length
        return l > 0 ? self / l : self
    }

    /// Angle in radians between two directions.
    @inlinable public func angle(to o: Vec3) -> Double {
        atan2(cross(o).length, dot(o))
    }

    public var description: String { "(\(x), \(y), \(z))" }
}

/// A point in the plane: face-local coordinates or unfolded map coordinates.
public struct Vec2: Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    @inlinable public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    @inlinable public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    @inlinable public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    @inlinable public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }
    @inlinable public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    @inlinable public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }

    @inlinable public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    /// The z component of the 3D cross product; positive when `o` is
    /// counter-clockwise from `self`.
    @inlinable public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    @inlinable public var lengthSquared: Double { dot(self) }
    @inlinable public var length: Double { lengthSquared.squareRoot() }
    @inlinable public var normalized: Vec2 {
        let l = length
        return l > 0 ? self / l : self
    }

    @inlinable public static func lerp(_ a: Vec2, _ b: Vec2, _ t: Double) -> Vec2 { a + (b - a) * t }

    public var description: String { "(\(x), \(y))" }
}

/// An axis-aligned rectangle in the plane.
public struct Rect2: Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// An empty rectangle that any union replaces.
    public static let empty = Rect2(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    @inlinable public init<S: Sequence>(bounding points: S) where S.Element == Vec2 {
        self = .empty
        for p in points { include(p) }
    }

    @inlinable public var isEmpty: Bool { minX > maxX || minY > maxY }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Vec2 { Vec2((minX + maxX) / 2, (minY + maxY) / 2) }

    @inlinable public mutating func include(_ p: Vec2) {
        minX = Swift.min(minX, p.x)
        minY = Swift.min(minY, p.y)
        maxX = Swift.max(maxX, p.x)
        maxY = Swift.max(maxY, p.y)
    }

    @inlinable public mutating func include(_ r: Rect2) {
        guard !r.isEmpty else { return }
        minX = Swift.min(minX, r.minX)
        minY = Swift.min(minY, r.minY)
        maxX = Swift.max(maxX, r.maxX)
        maxY = Swift.max(maxY, r.maxY)
    }

    @inlinable public func contains(_ p: Vec2) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    @inlinable public func intersects(_ r: Rect2) -> Bool {
        !(r.minX > maxX || r.maxX < minX || r.minY > maxY || r.maxY < minY)
    }

    public func insetBy(_ d: Double) -> Rect2 {
        Rect2(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d)
    }
}
