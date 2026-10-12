import Foundation

/// Planar polygon helpers. Polygons are open vertex lists (the closing edge
/// from the last vertex back to the first is implied).
public enum Planar {
    /// Shoelace area; positive for counter-clockwise polygons.
    public static func signedArea(_ poly: [Vec2]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var s = 0.0
        var prev = poly[poly.count - 1]
        for p in poly {
            s += prev.cross(p)
            prev = p
        }
        return s / 2
    }

    public static func centroid(_ poly: [Vec2]) -> Vec2 {
        let a = signedArea(poly)
        guard abs(a) > 1e-300 else {
            return poly.reduce(Vec2.zero, +) / Double(max(poly.count, 1))
        }
        var cx = 0.0, cy = 0.0
        var prev = poly[poly.count - 1]
        for p in poly {
            let k = prev.cross(p)
            cx += (prev.x + p.x) * k
            cy += (prev.y + p.y) * k
            prev = p
        }
        return Vec2(cx / (6 * a), cy / (6 * a))
    }

    /// Even-odd point-in-polygon test.
    public static func contains(_ poly: [Vec2], _ p: Vec2) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// True when `p` is inside or on the convex counter-clockwise polygon.
    public static func convexContains(_ convex: [Vec2], _ p: Vec2, tolerance: Double = 1e-12) -> Bool {
        var prev = convex[convex.count - 1]
        for c in convex {
            if (c - prev).cross(p - prev) < -tolerance { return false }
            prev = c
        }
        return true
    }

    /// Sutherland–Hodgman: clips any simple polygon against a convex
    /// counter-clockwise polygon. Concave subjects may gain zero-width
    /// bridges along the clip boundary, which do not change filled area.
    public static func clip(_ subject: [Vec2], toConvex clip: [Vec2]) -> [Vec2] {
        var output = subject
        var prev = clip[clip.count - 1]
        for c in clip {
            guard !output.isEmpty else { return [] }
            let edge = c - prev
            let input = output
            output = []
            output.reserveCapacity(input.count + 4)
            var s = input[input.count - 1]
            var sSide = edge.cross(s - prev)
            for e in input {
                let eSide = edge.cross(e - prev)
                if eSide >= 0 {
                    if sSide < 0 { output.append(Vec2.lerp(s, e, sSide / (sSide - eSide))) }
                    output.append(e)
                } else if sSide >= 0 {
                    output.append(Vec2.lerp(s, e, sSide / (sSide - eSide)))
                }
                s = e
                sSide = eSide
            }
            prev = c
        }
        return output.count >= 3 ? output : []
    }

    /// Cyrus–Beck: the part of segment `a`–`b` inside a convex
    /// counter-clockwise polygon, or nil.
    public static func clipSegment(_ a: Vec2, _ b: Vec2, toConvex clip: [Vec2]) -> (Vec2, Vec2)? {
        var t0 = 0.0, t1 = 1.0
        let d = b - a
        var prev = clip[clip.count - 1]
        for c in clip {
            let edge = c - prev
            // Inside means edge.cross(p - prev) >= 0.
            let num = edge.cross(a - prev)
            let den = edge.cross(d)
            if abs(den) < 1e-300 {
                if num < 0 { return nil }
            } else {
                let t = -num / den
                if den > 0 {
                    t0 = max(t0, t)
                } else {
                    t1 = min(t1, t)
                }
                if t0 > t1 { return nil }
            }
            prev = c
        }
        return (a + d * t0, a + d * t1)
    }

    /// Clips a polygon to the half-plane `value(p) >= 0` where `value` is
    /// supplied per vertex (linearly interpolated along edges).
    public static func clip(_ poly: [Vec2], values: [Double]) -> [Vec2] {
        guard !poly.isEmpty else { return [] }
        var output: [Vec2] = []
        var s = poly[poly.count - 1], sv = values[poly.count - 1]
        for (e, ev) in zip(poly, values) {
            if ev >= 0 {
                if sv < 0 { output.append(Vec2.lerp(s, e, sv / (sv - ev))) }
                output.append(e)
            } else if sv >= 0 {
                output.append(Vec2.lerp(s, e, sv / (sv - ev)))
            }
            s = e
            sv = ev
        }
        return output.count >= 3 ? output : []
    }
}

/// Clipping on the sphere, with arcs as great circles.
public enum SphericalClip {
    /// Clips a closed ring of unit vectors to the cap `dot(axis, p) >= minimumCosine`.
    /// New vertices lie on the great-circle arcs of the ring.
    public static func clipRing(_ ring: [Vec3], axis: Vec3, minimumCosine: Double) -> [Vec3] {
        guard let last = ring.last else { return [] }
        var output: [Vec3] = []
        var s = last
        var sv = axis.dot(s) - minimumCosine
        for e in ring {
            let ev = axis.dot(e) - minimumCosine
            if ev >= 0 {
                if sv < 0 { output.append(crossing(s, e, sv, ev)) }
                output.append(e)
            } else if sv >= 0 {
                output.append(crossing(s, e, sv, ev))
            }
            s = e
            sv = ev
        }
        return output
    }

    /// A point of the great-circle arc `a`–`b` on (or just inside) the cap
    /// boundary: the chord crossing of the cap plane, pushed back onto the
    /// sphere. It stays on the arc, which is all gnomonic projection needs.
    @inlinable static func crossing(_ a: Vec3, _ b: Vec3, _ av: Double, _ bv: Double) -> Vec3 {
        (a + (b - a) * (av / (av - bv))).normalized
    }
}
