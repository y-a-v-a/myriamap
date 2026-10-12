import Foundation

/// Orientation-preserving rigid motion of the plane.
public struct Rigid2D: Hashable, Sendable {
    public var cosine: Double
    public var sine: Double
    public var translation: Vec2

    public init(angle: Double, translation: Vec2) {
        cosine = cos(angle)
        sine = sin(angle)
        self.translation = translation
    }

    public init(cosine: Double, sine: Double, translation: Vec2) {
        self.cosine = cosine
        self.sine = sine
        self.translation = translation
    }

    public static let identity = Rigid2D(cosine: 1, sine: 0, translation: .zero)

    public var angle: Double { atan2(sine, cosine) }

    @inlinable public func apply(_ p: Vec2) -> Vec2 {
        Vec2(cosine * p.x - sine * p.y + translation.x, sine * p.x + cosine * p.y + translation.y)
    }

    @inlinable public func rotate(_ p: Vec2) -> Vec2 {
        Vec2(cosine * p.x - sine * p.y, sine * p.x + cosine * p.y)
    }

    public var inverse: Rigid2D {
        let t = Vec2(-(cosine * translation.x + sine * translation.y), sine * translation.x - cosine * translation.y)
        return Rigid2D(cosine: cosine, sine: -sine, translation: t)
    }

    /// `self` applied after `other`.
    public func concatenating(_ other: Rigid2D) -> Rigid2D {
        Rigid2D(cosine: cosine * other.cosine - sine * other.sine,
                sine: sine * other.cosine + cosine * other.sine,
                translation: apply(other.translation))
    }

    /// The motion taking `a` to `A` and the direction of `b - a` to that of `B - A`.
    public static func matching(_ a: Vec2, _ b: Vec2, to A: Vec2, _ B: Vec2) -> Rigid2D {
        let angle = atan2((B - A).y, (B - A).x) - atan2((b - a).y, (b - a).x)
        let c = cos(angle), s = sin(angle)
        let ra = Vec2(c * a.x - s * a.y, s * a.x + c * a.y)
        return Rigid2D(cosine: c, sine: s, translation: A - ra)
    }
}

/// A polyhedron unfolded into the plane along a spanning tree of its dual
/// graph. Tree edges are hinges where neighbouring faces stay attached;
/// every other edge is cut.
public struct Unfolding: Sendable {
    public let root: Int
    /// Parent face in the tree, -1 for the root.
    public let parent: [Int]
    /// Edge to the parent face, -1 for the root.
    public let parentEdge: [Int]
    /// Number of hinges between a face and the root.
    public let depth: [Int]
    /// Faces in breadth-first order from the root.
    public let order: [Int]
    /// Per edge: true when the edge is cut, false when it is a hinge.
    public let isCut: [Bool]
    /// Maps each face's local coordinates to map coordinates.
    public let transforms: [Rigid2D]

    /// - Parameters:
    ///   - hinges: per edge of `topology`, whether it belongs to the tree.
    ///   - root: face that keeps its local orientation (north up at its centre).
    public init(frames: [FaceFrame], polyhedron: Polyhedron, topology: MeshTopology, hinges: [Bool], root: Int) {
        let faceCount = polyhedron.faceCount
        var parent = Array(repeating: -1, count: faceCount)
        var parentEdge = Array(repeating: -1, count: faceCount)
        var depth = Array(repeating: -1, count: faceCount)
        var transforms = Array(repeating: Rigid2D.identity, count: faceCount)
        var order: [Int] = [root]
        order.reserveCapacity(faceCount)
        depth[root] = 0

        func localVertex(_ face: Int, _ vertex: Int) -> Vec2 {
            let i = polyhedron.faces[face].firstIndex(of: vertex)!
            return frames[face].localVertices[i]
        }

        var head = 0
        while head < order.count {
            let f = order[head]
            head += 1
            for e in topology.faceEdges[f] where hinges[e] {
                let edge = topology.edges[e]
                let g = edge.otherFace(f)
                guard depth[g] < 0 else { continue }
                depth[g] = depth[f] + 1
                parent[g] = f
                parentEdge[g] = e
                let A = transforms[f].apply(localVertex(f, edge.a))
                let B = transforms[f].apply(localVertex(f, edge.b))
                transforms[g] = Rigid2D.matching(localVertex(g, edge.a), localVertex(g, edge.b), to: A, B)
                order.append(g)
            }
        }
        precondition(order.count == faceCount, "hinges do not connect every face")

        self.root = root
        self.parent = parent
        self.parentEdge = parentEdge
        self.depth = depth
        self.order = order
        self.isCut = hinges.map { !$0 }
        self.transforms = transforms
    }

    public var cutCount: Int { isCut.lazy.filter { $0 }.count }
}
