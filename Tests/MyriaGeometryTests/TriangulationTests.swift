import Foundation
import Testing
@testable import MyriaGeometry

@Suite("Triangulation")
struct TriangulationTests {
    static func triangles(_ rings: [[Vec2]]) -> [[Vec2]] {
        var out: [Vec2] = []
        Triangulation.fill(rings, into: &out)
        #expect(out.count % 3 == 0)
        return stride(from: 0, to: out.count, by: 3).map { Array(out[$0..<($0 + 3)]) }
    }

    static func winding(_ rings: [[Vec2]], _ p: Vec2) -> Int {
        var w = 0
        for ring in rings {
            var a = ring[ring.count - 1]
            for b in ring {
                if a.y <= p.y, b.y > p.y, (b - a).cross(p - a) > 0 { w += 1 }
                if a.y > p.y, b.y <= p.y, (b - a).cross(p - a) < 0 { w -= 1 }
                a = b
            }
        }
        return w
    }

    static func distanceToRings(_ rings: [[Vec2]], _ p: Vec2) -> Double {
        var d = Double.infinity
        for ring in rings {
            var a = ring[ring.count - 1]
            for b in ring {
                let ab = b - a
                let t = min(max((p - a).dot(ab) / max(ab.lengthSquared, 1e-300), 0), 1)
                d = min(d, (a + ab * t - p).length)
                a = b
            }
        }
        return d
    }

    /// Every sample point away from the edges is covered exactly once where
    /// the winding is nonzero and not at all elsewhere.
    static func expectExactCover(_ rings: [[Vec2]], steps: Int = 60, sourceLocation: SourceLocation = #_sourceLocation) {
        let tris = triangles(rings)
        for t in tris {
            #expect(Planar.signedArea(t) >= 0, "clockwise triangle", sourceLocation: sourceLocation)
        }
        let box = Rect2(bounding: rings.flatMap { $0 })
        var misses = 0
        for i in 0...steps {
            for j in 0...steps {
                // Irrational offsets keep samples off grid-aligned edges.
                let p = Vec2(box.minX + (Double(i) + 0.31) / Double(steps + 1) * box.width,
                             box.minY + (Double(j) + 0.47) / Double(steps + 1) * box.height)
                guard distanceToRings(rings, p) > 1e-6 * max(box.width, box.height) else { continue }
                let covered = tris.filter { Planar.convexContains($0, p, tolerance: 0) }.count
                let expected = winding(rings, p) != 0 ? 1 : 0
                if covered != expected { misses += 1 }
            }
        }
        #expect(misses == 0, "\(misses) sample points covered wrongly", sourceLocation: sourceLocation)
    }

    static func area(_ rings: [[Vec2]]) -> Double {
        triangles(rings).reduce(0) { $0 + Planar.signedArea($1) }
    }

    static let square = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)]

    @Test func convexPolygonsBecomeFans() {
        let hexagon = (0..<6).map { Vec2(cos(Double($0) * .pi / 3), sin(Double($0) * .pi / 3)) }
        #expect(Self.triangles([hexagon]).count == 4)
        #expect(abs(Self.area([hexagon]) - Planar.signedArea(hexagon)) < 1e-12)
        // Collinear points (densified great-circle edges) keep it convex.
        let dense = [Vec2(0, 0), Vec2(0.5, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)]
        #expect(Self.triangles([dense]).count == 3)
    }

    @Test func holesAreLeftOpen() {
        let hole = [Vec2(0.3, 0.3), Vec2(0.3, 0.6), Vec2(0.7, 0.6), Vec2(0.7, 0.3)]
        #expect(abs(Self.area([Self.square, hole]) - (1 - 0.12)) < 1e-12)
        Self.expectExactCover([Self.square, hole])
        // A hole touching the outer ring along an edge, as when both are
        // clipped against the same face edge.
        let touching = [Vec2(0.4, 0), Vec2(0.4, 0.5), Vec2(0.8, 0.5), Vec2(0.8, 0)]
        #expect(abs(Self.area([Self.square, touching]) - 0.8) < 1e-12)
        Self.expectExactCover([Self.square, touching])
    }

    @Test func concavePolygonsAreCoveredExactly() {
        // A star and a comb: many notches opening up and down.
        let star = (0..<14).map { i -> Vec2 in
            let r = i % 2 == 0 ? 1.0 : 0.35 + 0.1 * Double(i % 3)
            let a = Double(i) * .pi / 7 + 0.05
            return Vec2(r * cos(a), r * sin(a))
        }
        #expect(abs(Self.area([star]) - Planar.signedArea(star)) < 1e-12)
        Self.expectExactCover([star])
        var comb = [Vec2(0, 0), Vec2(5, 0)]
        for k in stride(from: 4, through: 0, by: -1) {
            comb += [Vec2(Double(k) + 1, 2), Vec2(Double(k) + 0.6, 2), Vec2(Double(k) + 0.6, 0.7 + 0.1 * Double(k)),
                     Vec2(Double(k) + 0.4, 0.7 + 0.1 * Double(k))]
        }
        comb += [Vec2(0, 2)]
        Self.expectExactCover([comb])
        #expect(abs(Self.area([comb]) - Planar.signedArea(comb)) < 1e-9)
        // Trapezoids that meet share their corners.
        var vertices: [Vec2] = [], indices: [UInt32] = []
        Triangulation.fill([comb], vertices: &vertices, indices: &indices)
        #expect(indices.allSatisfy { Int($0) < vertices.count })
        #expect(vertices.count < indices.count / 3 * 2)
    }

    @Test func clippingArtefactsKeepTheirArea() {
        // Two lobes joined by a zero-width bridge along x = 1, as
        // Sutherland–Hodgman leaves when a concave polygon leaves and
        // re-enters the clip region.
        let bridged = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 3), Vec2(0, 3), Vec2(0, 2), Vec2(1, 2), Vec2(1, 1), Vec2(0, 1)]
        #expect(abs(Self.area([bridged]) - 2) < 1e-12)
        Self.expectExactCover([bridged])
        // Overlapping rings of the same orientation fill their union.
        let shifted = Self.square.map { $0 + Vec2(0.5, 0.25) }
        #expect(abs(Self.area([Self.square, shifted]) - (2 - 0.5 * 0.75)) < 1e-12)
        Self.expectExactCover([Self.square, shifted])
    }

    @Test func selfIntersectionsSplitTheSweep() {
        // A bow tie: both halves are filled under the nonzero rule.
        let bowtie = [Vec2(0, 0), Vec2(2, 2), Vec2(2, 0), Vec2(0, 2)]
        #expect(abs(Self.area([bowtie]) - 2) < 1e-12)
        Self.expectExactCover([bowtie])
    }

    @Test func randomPolygonsAreCoveredExactly() {
        var state: UInt64 = 0x9e3779b97f4a7c15
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for _ in 0..<40 {
            // Star-shaped around the origin, so simple; with a hole inside.
            let n = 5 + Int(random() * 30)
            let outer = (0..<n).map { i -> Vec2 in
                let a = (Double(i) + random() * 0.8) / Double(n) * 2 * .pi
                let r = 0.5 + random()
                return Vec2(r * cos(a), r * sin(a))
            }
            let hole = (0..<5).map { i -> Vec2 in
                let a = -Double(i) / 5 * 2 * .pi
                return Vec2(0.2 * cos(a), 0.2 * sin(a))
            }
            Self.expectExactCover([outer, hole], steps: 30)
            let expected = Planar.signedArea(outer) + Planar.signedArea(hole)
            #expect(abs(Self.area([outer, hole]) - expected) < 1e-9)
        }
    }
}
