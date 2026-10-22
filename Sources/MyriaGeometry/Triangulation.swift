import Foundation

/// Triangles for filling planar regions, for drawing on the GPU.
public enum Triangulation {
    /// Appends the fan of a convex counter-clockwise polygon.
    public static func fan(_ convex: [Vec2], into out: inout [Vec2]) {
        guard convex.count >= 3 else { return }
        for i in 1..<(convex.count - 1) {
            out.append(convex[0])
            out.append(convex[i])
            out.append(convex[i + 1])
        }
    }

    /// Appends triangles covering the points where the winding number of
    /// `rings` is nonzero (outer rings counter-clockwise, holes clockwise),
    /// as counter-clockwise vertex triples.
    public static func fill(_ rings: [[Vec2]], into out: inout [Vec2]) {
        var vertices: [Vec2] = [], indices: [UInt32] = []
        fill(rings, vertices: &vertices, indices: &indices)
        out += indices.map { vertices[Int($0)] }
    }

    /// Appends triangles covering the points where the winding number of
    /// `rings` is nonzero (outer rings counter-clockwise, holes clockwise),
    /// as corners and counter-clockwise triples of indices into `vertices`.
    /// Triangles that meet share their corners. A single convex ring
    /// becomes a fan.
    ///
    /// Anything else is swept bottom to top and cut into trapezoids between
    /// horizontal lines through the vertices; a trapezoid grows across those
    /// lines for as long as the same two edges bound it. Unlike ear clipping
    /// this needs no hole bridging, and it copes with the zero-width bridges,
    /// touching holes and overlapping rings that clipping produces.
    public static func fill(_ rings: [[Vec2]], vertices: inout [Vec2], indices: inout [UInt32]) {
        let rings = rings.filter { $0.count >= 3 }
        if rings.count == 1, isConvex(rings[0]) {
            let base = UInt32(vertices.count)
            vertices += rings[0]
            for i in 1..<UInt32(rings[0].count - 1) {
                indices.append(base)
                indices.append(base + i)
                indices.append(base + i + 1)
            }
            return
        }
        var edges: [Edge] = []
        var ys: [Double] = []
        var vertexCount = 0
        for ring in rings {
            // Ring vertices are numbered, so edges meeting at one share its corner.
            var a = ring[ring.count - 1], ia = vertexCount + ring.count - 1
            for (i, b) in ring.enumerated() {
                let ib = vertexCount + i
                // Horizontal edges never change the winding along a row.
                if a.y != b.y {
                    edges.append(a.y < b.y ? Edge(lo: a, hi: b, loVertex: ia, hiVertex: ib, winding: -1)
                                           : Edge(lo: b, hi: a, loVertex: ib, hiVertex: ia, winding: 1))
                    ys.append(a.y)
                    ys.append(b.y)
                }
                (a, ia) = (b, ib)
            }
            vertexCount += ring.count
        }
        guard edges.count >= 2 else { return }
        edges.sort { $0.lo.y < $1.lo.y }
        ys.sort()
        ys = ys.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
        var sweep = Sweep(edges: edges, vertexCount: vertexCount)
        sweep.run(ys: ys, vertices: &vertices, indices: &indices)
    }

    /// Convex and counter-clockwise, allowing collinear vertices but not
    /// edges that double back (the bridges clipping leaves behind).
    static func isConvex(_ ring: [Vec2]) -> Bool {
        var turning = 0.0
        var a = ring[ring.count - 2], b = ring[ring.count - 1]
        for c in ring {
            let u = b - a, v = c - b
            let cross = u.cross(v)
            if cross < -1e-12 * u.length * v.length { return false }
            if cross <= 1e-12 * u.length * v.length && u.dot(v) < 0 { return false }
            turning += atan2(cross, u.dot(v))
            (a, b) = (b, c)
        }
        // Once around, not a star that winds twice.
        return abs(turning - 2 * .pi) < 1e-6
    }

    struct Edge {
        /// Lower and upper end; `lo.y < hi.y`.
        let lo: Vec2
        let hi: Vec2
        /// The ring vertices at those ends.
        let loVertex: Int
        let hiVertex: Int
        /// Change of the winding number when crossing left to right: +1 for
        /// an edge the ring runs down.
        let winding: Int

        /// Exact at the ends, so trapezoids meeting there share corners.
        @inline(__always) func x(at y: Double) -> Double {
            if y <= lo.y { return lo.x }
            if y >= hi.y { return hi.x }
            return lo.x + (hi.x - lo.x) * ((y - lo.y) / (hi.y - lo.y))
        }
    }

    private struct Sweep {
        let edges: [Edge]
        /// The corner each edge has at the current level, valid while its
        /// stamp is the level's number.
        var corners: [UInt32]
        var stamps: [Int]
        /// The corner made at each ring vertex, if any.
        var vertexCorners: [UInt32?]

        init(edges: [Edge], vertexCount: Int) {
            self.edges = edges
            corners = Array(repeating: 0, count: edges.count)
            stamps = Array(repeating: -1, count: edges.count)
            vertexCorners = Array(repeating: nil, count: vertexCount)
        }

        /// A trapezoid that is still growing upwards, with its bottom corners.
        struct Open {
            let left: Int
            let right: Int
            let y: Double
            let bottomLeft: UInt32
            let bottomRight: UInt32
        }

        mutating func run(ys: [Double], vertices: inout [Vec2], indices: inout [UInt32]) {
            var ys = ys
            var active: [Int] = []
            var next = 0
            var open: [Open] = [], growing: [Open] = []
            var spans: [(Int, Int)] = []
            var keyed: [(x: Double, edge: Int)] = []
            var k = 0
            while k + 1 < ys.count {
                let y0 = ys[k]
                active.removeAll { edges[$0].hi.y <= y0 }
                while next < edges.count, edges[next].lo.y <= y0 {
                    if edges[next].hi.y > y0 { active.append(next) }
                    next += 1
                }
                var y1 = ys[k + 1]
                // Order the edges across the slab. Edges that cross inside it
                // (only self-intersecting input) split the slab at the crossing.
                for split in 0... {
                    let ym = (y0 + y1) / 2
                    keyed.removeAll(keepingCapacity: true)
                    for e in active { keyed.append((edges[e].x(at: ym), e)) }
                    keyed.sort { $0.x < $1.x }
                    for i in keyed.indices { active[i] = keyed[i].edge }
                    if split < 64, active.count > 1, let crossing = firstCrossing(active, y0, y1), crossing > y0, crossing < y1 {
                        ys.insert(crossing, at: k + 1)
                        y1 = crossing
                        continue
                    }
                    break
                }

                spans.removeAll(keepingCapacity: true)
                var winding = 0, left = -1
                for e in active {
                    let before = winding
                    winding += edges[e].winding
                    if before == 0, winding != 0 {
                        left = e
                    } else if before != 0, winding == 0 {
                        spans.append((left, e))
                    }
                }

                growing.removeAll(keepingCapacity: true)
                for (l, r) in spans {
                    if let i = open.firstIndex(where: { $0.left == l && $0.right == r }) {
                        growing.append(open.remove(at: i))
                    } else {
                        growing.append(Open(left: l, right: r, y: y0,
                                            bottomLeft: corner(l, y0, level: k, &vertices),
                                            bottomRight: corner(r, y0, level: k, &vertices)))
                    }
                }
                for t in open { close(t, at: y0, level: k, &vertices, &indices) }
                swap(&open, &growing)
                k += 1
            }
            if let top = ys.last {
                for t in open { close(t, at: top, level: ys.count - 1, &vertices, &indices) }
            }
        }

        /// The corner of edge `e` at the level `y`, made once per level, or
        /// once per ring vertex at the edge's ends.
        mutating func corner(_ e: Int, _ y: Double, level: Int, _ vertices: inout [Vec2]) -> UInt32 {
            if stamps[e] == level { return corners[e] }
            let edge = edges[e]
            let vertex = y == edge.lo.y ? edge.loVertex : (y == edge.hi.y ? edge.hiVertex : -1)
            let made: UInt32
            if vertex >= 0, let shared = vertexCorners[vertex] {
                made = shared
            } else {
                made = UInt32(vertices.count)
                vertices.append(Vec2(edge.x(at: y), y))
                if vertex >= 0 { vertexCorners[vertex] = made }
            }
            stamps[e] = level
            corners[e] = made
            return made
        }

        /// The lowest height inside (y0, y1) where neighbouring edges swap
        /// order, if any.
        func firstCrossing(_ sorted: [Int], _ y0: Double, _ y1: Double) -> Double? {
            var lowest: Double?
            for i in sorted.indices.dropLast() {
                let a = edges[sorted[i]], b = edges[sorted[i + 1]]
                let d0 = a.x(at: y0) - b.x(at: y0), d1 = a.x(at: y1) - b.x(at: y1)
                let tolerance = 1e-12 * (abs(a.x(at: y0)) + abs(b.x(at: y1)) + (y1 - y0))
                guard (d0 > tolerance && d1 < -tolerance) || (d0 < -tolerance && d1 > tolerance) else { continue }
                let y = y0 + (y1 - y0) * (d0 / (d0 - d1))
                if y > y0, y < y1, y < lowest ?? .infinity { lowest = y }
            }
            return lowest
        }

        mutating func close(_ t: Open, at top: Double, level: Int, _ vertices: inout [Vec2], _ indices: inout [UInt32]) {
            guard top > t.y else { return }
            let topLeft = corner(t.left, top, level: level, &vertices)
            let topRight = corner(t.right, top, level: level, &vertices)
            if vertices[Int(t.bottomRight)].x > vertices[Int(t.bottomLeft)].x {
                indices.append(t.bottomLeft)
                indices.append(t.bottomRight)
                indices.append(topRight)
            }
            if vertices[Int(topRight)].x > vertices[Int(topLeft)].x {
                indices.append(t.bottomLeft)
                indices.append(topRight)
                indices.append(topLeft)
            }
        }
    }
}
