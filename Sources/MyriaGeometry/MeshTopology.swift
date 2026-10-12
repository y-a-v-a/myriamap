import Foundation

/// An edge of the polyhedron shared by exactly two faces. In `leftFace` the
/// edge runs from `a` to `b`; in `rightFace` it runs from `b` to `a`.
public struct MeshEdge: Hashable, Sendable {
    public let a: Int
    public let b: Int
    public let leftFace: Int
    public let rightFace: Int

    public func otherFace(_ f: Int) -> Int { f == leftFace ? rightFace : leftFace }
}

public enum MeshTopologyError: Error, CustomStringConvertible {
    case nonManifoldEdge(Int, Int)
    case openEdge(Int, Int)

    public var description: String {
        switch self {
        case .nonManifoldEdge(let a, let b): "edge \(a)-\(b) is shared by more than two faces"
        case .openEdge(let a, let b): "edge \(a)-\(b) borders only one face"
        }
    }
}

/// Edge/face incidence of a closed polyhedron. The faces and the edges between
/// them form the dual graph on which the unfolding tree is built.
public struct MeshTopology: Sendable {
    public let edges: [MeshEdge]
    /// For each face, the edge index between vertex `i` and vertex `i + 1`.
    public let faceEdges: [[Int]]
    /// For each vertex, the incident edge indices.
    public let vertexEdges: [[Int]]

    public init(_ polyhedron: Polyhedron) throws {
        struct Partial { var a: Int, b: Int, left: Int, right: Int }
        var lookup: [UInt64: Int] = [:]
        var partial: [Partial] = []
        var faceEdges: [[Int]] = []
        faceEdges.reserveCapacity(polyhedron.faceCount)

        for (f, face) in polyhedron.faces.enumerated() {
            var ids: [Int] = []
            ids.reserveCapacity(face.count)
            for i in face.indices {
                let a = face[i], b = face[(i + 1) % face.count]
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if let e = lookup[key] {
                    guard partial[e].right < 0, partial[e].a == b else {
                        throw MeshTopologyError.nonManifoldEdge(a, b)
                    }
                    partial[e].right = f
                    ids.append(e)
                } else {
                    lookup[key] = partial.count
                    ids.append(partial.count)
                    partial.append(Partial(a: a, b: b, left: f, right: -1))
                }
            }
            faceEdges.append(ids)
        }
        if let open = partial.first(where: { $0.right < 0 }) {
            throw MeshTopologyError.openEdge(open.a, open.b)
        }
        edges = partial.map { MeshEdge(a: $0.a, b: $0.b, leftFace: $0.left, rightFace: $0.right) }
        self.faceEdges = faceEdges
        var vertexEdges = Array(repeating: [Int](), count: polyhedron.vertexCount)
        for (i, e) in edges.enumerated() {
            vertexEdges[e.a].append(i)
            vertexEdges[e.b].append(i)
        }
        self.vertexEdges = vertexEdges
    }

    public var edgeCount: Int { edges.count }

    /// Faces adjacent to `f`, in the order of its edges.
    public func neighbors(of f: Int) -> [Int] {
        faceEdges[f].map { edges[$0].otherFace(f) }
    }
}
