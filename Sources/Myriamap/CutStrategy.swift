import Foundation
import MyriaGeometry

/// Decides where the myriahedron is cut. The result is a spanning tree of
/// the dual graph: its edges are the hinges, every other edge is cut.
public protocol CutStrategy: Sendable {
    /// Per edge: true when the edge stays a hinge.
    /// - Parameter faceGroups: a label per face (zone group, land/water, …).
    func hinges(mesh: MyriahedralMesh, faceGroups: [Int], root: Int) -> [Bool]
}

/// Cuts along timezone borders.
///
/// 1. Inside each zone the hinges are a maximum spanning tree over the
///    zone's own edges: east–west neighbours first (rows of faces become
///    strips), then north–south links where the rows are deepest inside the
///    zone. Each zone unfolds like a small polyconic map, its slits running
///    along parallels in from the border.
/// 2. The zone pieces are then joined by one hinge each across a border,
///    grown outward from the root piece (Prim's algorithm on pieces). A
///    candidate hinge scores high near the equator and the central meridian,
///    and low when it would hang its piece at a tilt; the tilt is exact,
///    since a piece's internal tree fixes how its faces rotate relative to
///    each other. The zones hang off an equatorial belt like globe gores, the
///    belt opens on the far side of the globe, and northern zones that don't
///    reach the equator stay upright.
public struct TimeZoneCutStrategy: CutStrategy, Hashable {
    /// Longitude the equatorial belt is centred on.
    public var centerLongitude: Double
    /// How strongly cross-border hinges prefer low latitudes.
    public var equatorBias: Double
    /// Tilt (radians) at which a hinge's score has dropped by a factor e.
    public var tiltTolerance: Double

    public init(centerLongitude: Double = 0, equatorBias: Double = 2, tiltTolerance: Double = 0.35) {
        self.centerLongitude = centerLongitude
        self.equatorBias = equatorBias
        self.tiltTolerance = tiltTolerance
    }

    public func hinges(mesh: MyriahedralMesh, faceGroups: [Int], root: Int) -> [Bool] {
        let edges = mesh.topology.edges
        let centers = (0..<mesh.faceCount).map { mesh.polyhedron.faceCenter($0) }
        let geometry = edges.map { EdgeGeometry(edge: $0, mesh: mesh, centers: centers) }
        let internalWeights = internalWeights(mesh: mesh, faceGroups: faceGroups, geometry: geometry)

        // 1. Spanning forest inside the zones.
        let internalEdges = edges.indices.filter { faceGroups[edges[$0].leftFace] == faceGroups[edges[$0].rightFace] }
        let inForest = SpanningTree.maximum(nodeCount: mesh.faceCount,
                                            edges: internalEdges.map { (edges[$0].leftFace, edges[$0].rightFace) },
                                            weights: internalEdges.map { internalWeights[$0] })
        var hinges = Array(repeating: false, count: edges.count)
        for (i, e) in internalEdges.enumerated() where inForest[i] { hinges[e] = true }

        // 2. Join the pieces.
        let pieces = PieceRotations(mesh: mesh, hinges: hinges)
        for e in attachPieces(mesh: mesh, pieces: pieces, geometry: geometry, root: root) { hinges[e] = true }
        return hinges
    }

    /// Weights of edges inside a zone, in 2...2.5.
    func internalWeights(mesh: MyriahedralMesh, faceGroups: [Int], geometry: [EdgeGeometry]) -> [Double] {
        let depth = Self.eastWestDepth(mesh: mesh, faceGroups: faceGroups, geometry: geometry)
        let maxDepth = Double(depth.filter { $0 < Int.max }.max() ?? 0) + 1
        return mesh.topology.edges.indices.map { e in
            let edge = mesh.topology.edges[e], g = geometry[e]
            guard faceGroups[edge.leftFace] == faceGroups[edge.rightFace] else { return 0 }
            let d = Double(min(depth[edge.leftFace], depth[edge.rightFace], Int(maxDepth))) / maxDepth
            return 2 + 0.5 * g.eastWestness + 0.5 * (1 - g.eastWestness) * d
        }
    }

    /// Score of hanging a piece from an already placed face across an edge.
    func score(midpoint: Vec3, tilt: Double) -> Double {
        let p = GeoPoint(midpoint)
        let equator = pow(cos(p.latitude * .pi / 180), equatorBias)
        let away = abs(Spherical.longitudeDelta(centerLongitude, p.longitude)) / 180
        return equator * (1 - 0.5 * away) * exp(-pow(tilt / tiltTolerance, 2))
    }

    /// Prim's algorithm over pieces; returns the chosen border hinges.
    func attachPieces(mesh: MyriahedralMesh, pieces: PieceRotations, geometry: [EdgeGeometry], root: Int) -> [Int] {
        let edges = mesh.topology.edges
        var placed = Array(repeating: false, count: pieces.count)
        var offset = Array(repeating: 0.0, count: pieces.count)  // piece frame → map rotation
        var frontier: [(edge: Int, from: Int, score: Double, offset: Double)] = []
        var chosen: [Int] = []

        func place(_ piece: Int, rotation: Double) {
            placed[piece] = true
            offset[piece] = rotation
            for f in pieces.faces[piece] {
                for e in mesh.topology.faceEdges[f] {
                    let c = edges[e].otherFace(f)
                    let target = pieces.piece[c]
                    guard !placed[target] else { continue }
                    // Rotation of face c once hinged to f, then of its piece.
                    let faceAngle = rotation + pieces.angle[f] + pieces.hingeRotation(edge: e, from: c, to: f)
                    let pieceOffset = faceAngle - pieces.angle[c]
                    let tilt = Self.wrap(pieceOffset + pieces.meanAngle[target])
                    frontier.append((e, f, score(midpoint: geometry[e].midpoint, tilt: tilt), pieceOffset))
                }
            }
        }

        place(pieces.piece[root], rotation: -pieces.angle[root])
        while true {
            frontier.removeAll { placed[pieces.piece[edges[$0.edge].otherFace($0.from)]] }
            guard let best = frontier.indices.max(by: { frontier[$0].score < frontier[$1].score || (frontier[$0].score == frontier[$1].score && frontier[$0].edge > frontier[$1].edge) })
            else { break }
            let candidate = frontier.remove(at: best)
            chosen.append(candidate.edge)
            place(pieces.piece[edges[candidate.edge].otherFace(candidate.from)], rotation: candidate.offset)
        }
        return chosen
    }

    static func wrap(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }

    /// Hops from each face to the nearest zone border travelling only
    /// east–west within the zone. Rows that never meet a border (around a
    /// pole) get `Int.max`.
    static func eastWestDepth(mesh: MyriahedralMesh, faceGroups: [Int], geometry: [EdgeGeometry]) -> [Int] {
        var depth = Array(repeating: Int.max, count: mesh.faceCount)
        var queue: [Int] = []
        for (e, edge) in mesh.topology.edges.enumerated() where geometry[e].eastWestness >= 0.5 {
            if faceGroups[edge.leftFace] != faceGroups[edge.rightFace] {
                for f in [edge.leftFace, edge.rightFace] where depth[f] != 0 {
                    depth[f] = 0
                    queue.append(f)
                }
            }
        }
        var head = 0
        while head < queue.count {
            let f = queue[head]
            head += 1
            for e in mesh.topology.faceEdges[f] where geometry[e].eastWestness >= 0.5 {
                let g = mesh.topology.edges[e].otherFace(f)
                if faceGroups[g] == faceGroups[f] && depth[g] == Int.max {
                    depth[g] = depth[f] + 1
                    queue.append(g)
                }
            }
        }
        return depth
    }
}

/// Pieces of a spanning forest and how their faces rotate relative to each
/// other once unfolded.
struct PieceRotations {
    let mesh: MyriahedralMesh
    /// Piece index per face.
    let piece: [Int]
    let faces: [[Int]]
    /// Rotation of each face's local frame in its piece's frame.
    let angle: [Double]
    /// Area-weighted circular mean of `angle` per piece.
    let meanAngle: [Double]

    var count: Int { faces.count }

    init(mesh: MyriahedralMesh, hinges: [Bool]) {
        self.mesh = mesh
        let n = mesh.faceCount
        var piece = Array(repeating: -1, count: n)
        var angle = Array(repeating: 0.0, count: n)
        var faces: [[Int]] = []
        for start in 0..<n where piece[start] < 0 {
            let id = faces.count
            var members = [start]
            piece[start] = id
            var head = 0
            while head < members.count {
                let f = members[head]
                head += 1
                for e in mesh.topology.faceEdges[f] where hinges[e] {
                    let g = mesh.topology.edges[e].otherFace(f)
                    guard piece[g] < 0 else { continue }
                    piece[g] = id
                    angle[g] = angle[f] + Self.hingeRotation(mesh: mesh, edge: e, from: g, to: f)
                    members.append(g)
                }
            }
            faces.append(members)
        }
        self.piece = piece
        self.faces = faces
        self.angle = angle
        meanAngle = faces.map { members in
            var s = 0.0, c = 0.0
            for f in members {
                let w = mesh.frames[f].area
                s += w * sin(angle[f])
                c += w * cos(angle[f])
            }
            return atan2(s, c)
        }
    }

    func hingeRotation(edge e: Int, from child: Int, to parent: Int) -> Double {
        Self.hingeRotation(mesh: mesh, edge: e, from: child, to: parent)
    }

    /// Rotation taking `child`'s local frame onto `parent`'s when the two are
    /// unfolded around their shared edge.
    static func hingeRotation(mesh: MyriahedralMesh, edge e: Int, from child: Int, to parent: Int) -> Double {
        let edge = mesh.topology.edges[e]
        func local(_ f: Int, _ v: Int) -> Vec2 {
            mesh.frames[f].localVertices[mesh.polyhedron.faces[f].firstIndex(of: v)!]
        }
        let dc = local(child, edge.b) - local(child, edge.a)
        let dp = local(parent, edge.b) - local(parent, edge.a)
        return atan2(dp.y, dp.x) - atan2(dc.y, dc.x)
    }
}

/// Cuts through the oceans and keeps land masses whole: van Wijk's original
/// geographic weighting, for comparison.
public struct LandmassCutStrategy: CutStrategy, Hashable {
    public var centerLongitude: Double

    public init(centerLongitude: Double = 0) {
        self.centerLongitude = centerLongitude
    }

    /// `faceGroups` holds 1 for land faces and 0 for water.
    public func hinges(mesh: MyriahedralMesh, faceGroups: [Int], root: Int) -> [Bool] {
        SpanningTree.maximum(nodeCount: mesh.faceCount, edges: mesh.dualEdges,
                             weights: weights(mesh: mesh, faceGroups: faceGroups))
    }

    public func weights(mesh: MyriahedralMesh, faceGroups: [Int]) -> [Double] {
        let centers = (0..<mesh.faceCount).map { mesh.polyhedron.faceCenter($0) }
        return mesh.topology.edges.map { edge in
            let g = EdgeGeometry(edge: edge, mesh: mesh, centers: centers)
            let land = Double(faceGroups[edge.leftFace] + faceGroups[edge.rightFace])
            let latitude = GeoPoint(g.midpoint).latitude * .pi / 180
            let away = abs(Spherical.longitudeDelta(centerLongitude, GeoPoint(g.midpoint).longitude)) / 180
            return land + 0.5 * cos(latitude) * (1 - 0.5 * away) + 0.25 * g.eastWestness
        }
    }
}

/// Where an edge lies and which way it is crossed.
struct EdgeGeometry {
    let midpoint: Vec3
    /// 1 when the edge is crossed travelling east–west, 0 north–south.
    let eastWestness: Double

    init(edge: MeshEdge, mesh: MyriahedralMesh, centers: [Vec3]) {
        let a = mesh.polyhedron.vertices[edge.a], b = mesh.polyhedron.vertices[edge.b]
        midpoint = (a + b).normalized
        let (east, north) = Spherical.tangentFrame(at: midpoint)
        let d = centers[edge.rightFace] - centers[edge.leftFace]
        let de = d.dot(east), dn = d.dot(north)
        let total = de * de + dn * dn
        eastWestness = total > 0 ? de * de / total : 0.5
    }
}
