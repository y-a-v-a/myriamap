import Foundation

/// A closed polyhedron whose vertices lie on the unit sphere: the
/// "myriahedron" that approximates the globe with many small flat faces.
///
/// Faces are planar convex polygons listed counter-clockwise as seen from
/// outside the sphere.
public struct Polyhedron: Sendable {
    public private(set) var vertices: [Vec3]
    public private(set) var faces: [[Int]]

    /// Creates a polyhedron, normalising every vertex onto the unit sphere and
    /// reversing any face listed clockwise.
    public init(vertices: [Vec3], faces: [[Int]]) {
        self.vertices = vertices.map(\.normalized)
        self.faces = faces.map { face in
            let pts = face.map { vertices[$0] }
            let normal = Polyhedron.newellNormal(pts)
            let centroid = pts.reduce(Vec3.zero, +)
            return normal.dot(centroid) < 0 ? Array(face.reversed()) : face
        }
    }

    public var faceCount: Int { faces.count }
    public var vertexCount: Int { vertices.count }

    public func faceVertices(_ f: Int) -> [Vec3] { faces[f].map { vertices[$0] } }

    /// Direction of the face's centre on the unit sphere.
    public func faceCenter(_ f: Int) -> Vec3 {
        faces[f].reduce(Vec3.zero) { $0 + vertices[$1] }.normalized
    }

    /// Returns the polyhedron rotated so that `from` ends up at `to`.
    public func rotated(from: Vec3, to: Vec3) -> Polyhedron {
        var copy = self
        copy.vertices = vertices.map { Spherical.rotate($0, from: from, to: to) }
        return copy
    }

    /// Robust polygon normal (Newell's method), not normalised.
    static func newellNormal(_ pts: [Vec3]) -> Vec3 {
        var n = Vec3.zero
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
        }
        return n
    }
}

// MARK: - Generators

extension Polyhedron {
    /// The regular icosahedron with one vertex at each pole.
    public static func icosahedron() -> Polyhedron {
        let phi = (1 + 5.0.squareRoot()) / 2
        var v: [Vec3] = []
        for a in [-1.0, 1.0] {
            for b in [-phi, phi] {
                v.append(Vec3(0, a, b))
                v.append(Vec3(a, b, 0))
                v.append(Vec3(b, 0, a))
            }
        }
        // Faces are the vertex triples that are pairwise one edge (length 2) apart.
        var faces: [[Int]] = []
        for i in 0..<12 {
            for j in (i + 1)..<12 where abs((v[i] - v[j]).length - 2) < 1e-9 {
                for k in (j + 1)..<12
                where abs((v[i] - v[k]).length - 2) < 1e-9 && abs((v[j] - v[k]).length - 2) < 1e-9 {
                    faces.append([i, j, k])
                }
            }
        }
        let ico = Polyhedron(vertices: v, faces: faces)
        // Put a vertex on the north pole; rotate about the axis so a second
        // vertex lies on the prime meridian for a reproducible orientation.
        let up = ico.rotated(from: ico.vertices[0], to: .unitZ)
        let neighbor = up.vertices.first { abs($0.z - 1 / 5.0.squareRoot()) < 1e-6 } ?? up.vertices[1]
        let azimuth = atan2(neighbor.y, neighbor.x)
        return up.rotatedAboutPolarAxis(by: -azimuth)
    }

    /// Geodesic sphere: every icosahedron face divided into `frequency²`
    /// triangles whose vertices are projected onto the sphere.
    public static func geodesic(frequency n: Int) -> Polyhedron {
        precondition(n >= 1, "frequency must be at least 1")
        let base = icosahedron()
        enum Key: Hashable {
            case vertex(Int)
            case edge(Int, Int, Int)  // (lower vertex, higher vertex, steps from lower)
            case interior(Int, Int, Int)  // (face, i, j)
        }
        var index: [Key: Int] = [:]
        var vertices: [Vec3] = []
        var faces: [[Int]] = []
        faces.reserveCapacity(20 * n * n)

        for (f, face) in base.faces.enumerated() {
            let ids = face
            let corners = face.map { base.vertices[$0] }
            func vertexID(_ i: Int, _ j: Int) -> Int {
                // Barycentric weights (n - i - j, i, j) over the face corners.
                let weights = [n - i - j, i, j]
                let nonzero = (0..<3).filter { weights[$0] > 0 }
                let key: Key
                if nonzero.count == 1 {
                    key = .vertex(ids[nonzero[0]])
                } else if nonzero.count == 2 {
                    let (p, q) = (nonzero[0], nonzero[1])
                    let (lo, hi) = ids[p] < ids[q] ? (p, q) : (q, p)
                    key = .edge(ids[lo], ids[hi], weights[hi])
                } else {
                    key = .interior(f, i, j)
                }
                if let existing = index[key] { return existing }
                let position: Vec3
                switch key {
                case .vertex(let id):
                    position = base.vertices[id]
                case .edge(let lo, let hi, let steps):
                    let a = base.vertices[lo], b = base.vertices[hi]
                    position = (a * Double(n - steps) + b * Double(steps)) / Double(n)
                case .interior:
                    position = (corners[0] * Double(weights[0]) + corners[1] * Double(weights[1])
                        + corners[2] * Double(weights[2])) / Double(n)
                }
                vertices.append(position.normalized)
                index[key] = vertices.count - 1
                return vertices.count - 1
            }
            for i in 0..<n {
                for j in 0..<(n - i) {
                    faces.append([vertexID(i, j), vertexID(i + 1, j), vertexID(i, j + 1)])
                    if i + j + 2 <= n {
                        faces.append([vertexID(i + 1, j), vertexID(i + 1, j + 1), vertexID(i, j + 1)])
                    }
                }
            }
        }
        return Polyhedron(vertices: vertices, faces: faces)
    }

    /// Latitude/longitude grid: quadrilateral cells (planar isosceles
    /// trapezoids) with triangle fans around the poles. Meridians lie at
    /// `-180 + k * longitudeStep`, so a step dividing 7.5° aligns cell edges
    /// with the nautical timezone boundaries.
    public static func graticule(latitudeStep: Double, longitudeStep: Double) -> Polyhedron {
        let rows = max(2, Int((180 / latitudeStep).rounded()))
        let cols = max(3, Int((360 / longitudeStep).rounded()))
        let dLat = 180.0 / Double(rows), dLon = 360.0 / Double(cols)
        var vertices: [Vec3] = [.unitZ, -Vec3.unitZ]
        func ring(_ k: Int) -> Int { 2 + (k - 1) * cols }  // first vertex of ring k (1...rows-1)
        for k in 1..<rows {
            let lat = 90 - Double(k) * dLat
            for j in 0..<cols {
                vertices.append(GeoPoint(latitude: lat, longitude: -180 + Double(j) * dLon).unitVector)
            }
        }
        var faces: [[Int]] = []
        for j in 0..<cols {
            let next = (j + 1) % cols
            faces.append([0, ring(1) + j, ring(1) + next])
        }
        for k in 1..<(rows - 1) {
            for j in 0..<cols {
                let next = (j + 1) % cols
                faces.append([ring(k) + j, ring(k + 1) + j, ring(k + 1) + next, ring(k) + next])
            }
        }
        for j in 0..<cols {
            let next = (j + 1) % cols
            faces.append([1, ring(rows - 1) + next, ring(rows - 1) + j])
        }
        return Polyhedron(vertices: vertices, faces: faces)
    }

    func rotatedAboutPolarAxis(by angle: Double) -> Polyhedron {
        var copy = self
        let c = cos(angle), s = sin(angle)
        copy.vertices = vertices.map { Vec3(c * $0.x - s * $0.y, s * $0.x + c * $0.y, $0.z) }
        return copy
    }
}
