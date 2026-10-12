import Foundation

/// Finds the polyhedron face whose spherical polygon contains a point, using a
/// latitude/longitude bucket grid over the faces' bounding caps.
public struct FaceLocator: Sendable {
    /// Per face, the inward-facing edge plane normals `v[i] × v[i+1]`.
    let edgeNormals: [[Vec3]]
    let buckets: [[Int32]]
    let rows: Int
    let cols: Int
    let cellSize: Double

    public init(polyhedron: Polyhedron) {
        let faceCount = polyhedron.faceCount
        var normals: [[Vec3]] = []
        normals.reserveCapacity(faceCount)
        var caps: [(center: GeoPoint, radius: Double)] = []
        caps.reserveCapacity(faceCount)
        var meanRadius = 0.0
        for f in 0..<faceCount {
            let verts = polyhedron.faceVertices(f)
            normals.append(verts.indices.map { verts[$0].cross(verts[($0 + 1) % verts.count]) })
            let c = polyhedron.faceCenter(f)
            let r = verts.map { c.angle(to: $0) }.max()! * 180 / .pi
            caps.append((GeoPoint(c), r))
            meanRadius += r
        }
        meanRadius /= Double(max(faceCount, 1))
        // Cells of roughly one face across keep bucket lists short.
        let cell = min(max(meanRadius * 1.5, 0.25), 10)
        let rows = Int((180 / cell).rounded(.up))
        let cols = Int((360 / cell).rounded(.up))
        var buckets = Array(repeating: [Int32](), count: rows * cols)

        for (f, cap) in caps.enumerated() {
            let r = cap.radius + 1e-6
            let lat0 = cap.center.latitude - r, lat1 = cap.center.latitude + r
            let r0 = max(0, Int(((lat0 + 90) / cell).rounded(.down)))
            let r1 = min(rows - 1, Int(((lat1 + 90) / cell).rounded(.down)))
            var colRanges: [ClosedRange<Int>]
            let cosLat = cos(cap.center.latitude * .pi / 180)
            let sinR = sin(r * .pi / 180)
            if lat0 <= -90 || lat1 >= 90 || sinR >= cosLat {
                colRanges = [0...(cols - 1)]
            } else {
                let dLon = asin(sinR / cosLat) * 180 / .pi
                let c0 = Int(((cap.center.longitude - dLon + 180) / cell).rounded(.down))
                let c1 = Int(((cap.center.longitude + dLon + 180) / cell).rounded(.down))
                if c1 - c0 + 1 >= cols {
                    colRanges = [0...(cols - 1)]
                } else {
                    colRanges = [c0...c1]
                }
            }
            for row in r0...r1 {
                for range in colRanges {
                    for c in range {
                        let col = ((c % cols) + cols) % cols
                        buckets[row * cols + col].append(Int32(f))
                    }
                }
            }
        }
        edgeNormals = normals
        self.buckets = buckets
        self.rows = rows
        self.cols = cols
        cellSize = cell
    }

    /// How far `p` is inside face `f`: the minimum over its edge planes
    /// (negative when outside).
    func insideness(_ f: Int, _ p: Vec3) -> Double {
        var m = Double.infinity
        for n in edgeNormals[f] {
            m = min(m, n.dot(p))
        }
        return m
    }

    func bucket(of p: Vec3) -> Int {
        let g = GeoPoint(p)
        let row = min(rows - 1, max(0, Int(((g.latitude + 90) / cellSize).rounded(.down))))
        let col = ((Int(((g.longitude + 180) / cellSize).rounded(.down)) % cols) + cols) % cols
        return row * cols + col
    }

    /// The face containing direction `p`. Points on shared edges resolve to
    /// one of the adjacent faces.
    public func face(containing p: Vec3) -> Int {
        let candidates = buckets[bucket(of: p)]
        var best = -1
        var bestValue = -Double.infinity
        for c in candidates {
            let v = insideness(Int(c), p)
            if v >= 0 { return Int(c) }
            if v > bestValue {
                bestValue = v
                best = Int(c)
            }
        }
        if best >= 0 && bestValue > -1e-9 { return best }
        // Fall back to a full scan; only reachable through numerical trouble.
        for f in edgeNormals.indices {
            let v = insideness(f, p)
            if v > bestValue {
                bestValue = v
                best = f
            }
        }
        return best
    }

    /// Faces whose bounding caps overlap the bucket of `p`.
    public func candidates(near p: Vec3) -> [Int] {
        buckets[bucket(of: p)].map(Int.init)
    }
}
