import Foundation

/// A geographic location in degrees.
public struct GeoPoint: Hashable, Sendable, CustomStringConvertible {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The location of a direction from the centre of the globe.
    public init(_ v: Vec3) {
        latitude = atan2(v.z, (v.x * v.x + v.y * v.y).squareRoot()) * 180 / .pi
        longitude = atan2(v.y, v.x) * 180 / .pi
    }

    /// The point on the unit sphere. Longitude 0 lies along +x, 90°E along +y
    /// and the north pole at +z.
    public var unitVector: Vec3 {
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        let c = cos(lat)
        return Vec3(c * cos(lon), c * sin(lon), sin(lat))
    }

    /// Great-circle distance in radians on the unit sphere.
    public func distance(to other: GeoPoint) -> Double {
        unitVector.angle(to: other.unitVector)
    }

    public var description: String {
        String(format: "%.4f°%@ %.4f°%@", abs(latitude), latitude >= 0 ? "N" : "S",
               abs(longitude), longitude >= 0 ? "E" : "W")
    }
}

public enum Spherical {
    /// Wraps a longitude into [-180, 180).
    public static func normalizeLongitude(_ lon: Double) -> Double {
        var l = (lon + 180).truncatingRemainder(dividingBy: 360)
        if l < 0 { l += 360 }
        return l - 180
    }

    /// Signed smallest difference `b - a` between two longitudes, in (-180, 180].
    public static func longitudeDelta(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// East and north unit tangents at a point of the unit sphere. Near the
    /// poles, where east is undefined, the tangent towards +y stands in.
    public static func tangentFrame(at v: Vec3) -> (east: Vec3, north: Vec3) {
        let p = v.normalized
        var east = Vec3.unitZ.cross(p)
        if east.lengthSquared < 1e-18 {
            east = Vec3.unitY - p * p.dot(.unitY)
        }
        east = east.normalized
        return (east, p.cross(east))
    }

    /// Point on the great-circle arc from `a` to `b` at fraction `t`.
    public static func slerp(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 {
        let omega = a.angle(to: b)
        if omega < 1e-12 { return a }
        let s = sin(omega)
        return a * (sin((1 - t) * omega) / s) + b * (sin(t * omega) / s)
    }

    /// Rotation taking unit vector `from` onto unit vector `to`, applied to `v`
    /// (Rodrigues' formula).
    public static func rotate(_ v: Vec3, from: Vec3, to: Vec3) -> Vec3 {
        let f = from.normalized, t = to.normalized
        let axis = f.cross(t)
        let s = axis.length
        let c = f.dot(t)
        if s < 1e-15 {
            if c > 0 { return v }
            // Half turn about any axis perpendicular to `from`.
            var perp = f.cross(.unitX)
            if perp.lengthSquared < 1e-12 { perp = f.cross(.unitY) }
            perp = perp.normalized
            return perp * (2 * perp.dot(v)) - v
        }
        let k = axis / s
        return v * c + k.cross(v) * s + k * (k.dot(v) * (1 - c))
    }

    /// Area of a spherical triangle on the unit sphere (its spherical excess).
    public static func triangleArea(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        let numerator = abs(a.dot(b.cross(c)))
        let denominator = 1 + a.dot(b) + b.dot(c) + c.dot(a)
        return 2 * atan2(numerator, denominator)
    }
}
