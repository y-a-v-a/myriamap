import Foundation
import Testing
@testable import MyriaGeometry

@Suite("Folding")
struct FoldingTests {
    static let mesh = try! MyriahedralMesh(.geodesic(frequency: 5))
    static let map = mesh.unfold(weights: UnfoldingTests.pseudoRandomWeights(mesh.topology.edgeCount, seed: 11), root: 4)
    static let folding = Folding(projection: map)

    func world(_ poses: [Pose3], face f: Int, vertex i: Int) -> Vec3 {
        poses[f].apply(Self.mesh.frames[f].localVertices[i])
    }

    @Test func flatPosesReproduceTheMap() {
        let poses = Self.folding.poses(unfold: 1)
        for f in 0..<Self.mesh.faceCount {
            for (i, q) in Self.map.mapPolygons[f].enumerated() {
                let p = world(poses, face: f, vertex: i)
                #expect(abs(p.z) < 1e-9)
                #expect((Vec2(p.x, p.y) - q).length < 1e-9)
            }
        }
    }

    @Test func closedPosesReproduceThePolyhedron() {
        // A rigid copy of the polyhedron: every pairwise vertex distance
        // matches the original, across faces far apart in the tree.
        let poses = Self.folding.poses(unfold: 0)
        let faces = Self.mesh.polyhedron.faces
        let probes = stride(from: 0, to: Self.mesh.faceCount, by: 37).map { $0 }
        for f in probes {
            for g in probes {
                let original = (Self.mesh.polyhedron.vertices[faces[f][0]] - Self.mesh.polyhedron.vertices[faces[g][1]]).length
                let folded = (world(poses, face: f, vertex: 0) - world(poses, face: g, vertex: 1)).length
                #expect(abs(original - folded) < 1e-9)
            }
        }
        // Shared vertices meet again across cut edges.
        for e in Self.map.cutEdges.prefix(200) {
            let edge = Self.mesh.topology.edges[e]
            let left = world(poses, face: edge.leftFace, vertex: faces[edge.leftFace].firstIndex(of: edge.a)!)
            let right = world(poses, face: edge.rightFace, vertex: faces[edge.rightFace].firstIndex(of: edge.a)!)
            #expect((left - right).length < 1e-9)
        }
    }

    @Test func closedPolyhedronBulgesAwayFromTheViewer() {
        // The root face is in z = 0 facing +z; the rest of the globe lies behind it.
        let poses = Self.folding.poses(unfold: 0)
        for f in 0..<Self.mesh.faceCount {
            #expect(world(poses, face: f, vertex: 0).z <= 1e-9)
        }
    }

    @Test func hingesHoldDuringTheAnimation() {
        let poses = Self.folding.poses(unfold: 0.37)
        let faces = Self.mesh.polyhedron.faces
        for (e, edge) in Self.mesh.topology.edges.enumerated() where !Self.map.unfolding.isCut[e] {
            for v in [edge.a, edge.b] {
                let left = world(poses, face: edge.leftFace, vertex: faces[edge.leftFace].firstIndex(of: v)!)
                let right = world(poses, face: edge.rightFace, vertex: faces[edge.rightFace].firstIndex(of: v)!)
                #expect((left - right).length < 1e-9)
            }
        }
    }

    @Test func largeMeshesArePosedInParallelBranches() {
        // Big enough to split into a trunk and parallel branches.
        let mesh = try! MyriahedralMesh(.geodesic(frequency: 16))
        let map = mesh.unfold(weights: UnfoldingTests.pseudoRandomWeights(mesh.topology.edgeCount, seed: 3), root: 17)
        let folding = Folding(projection: map)
        #expect(!folding.branches.isEmpty)
        // Every face exactly once, and every parent posed before its child.
        let sequence = folding.trunk + folding.branches.flatMap { $0 }
        #expect(sequence.sorted() == Array(0..<mesh.faceCount))
        let trunk = Set(folding.trunk)
        for branch in folding.branches {
            var seen = Set<Int>()
            for f in branch {
                let p = folding.parent[f]
                #expect(trunk.contains(p) || seen.contains(p))
                seen.insert(f)
            }
        }
        // The same poses as composing hinge and placement one face at a time.
        let camera = Pose3(rotation: .rotation(axis: Vec3(1, 2, 3).normalized, angle: 0.3), translation: Vec3(0.1, -0.2, 0.3))
        for unfold in [0.0, 0.37, 1.0] {
            var poses: [Pose3] = []
            folding.poses(unfold: unfold, camera: camera, into: &poses)
            var expected = Array(repeating: camera, count: mesh.faceCount)
            for f in folding.order where folding.parent[f] >= 0 {
                let rotation = Mat3.rotation(axis: folding.hingeAxis[f], angle: folding.closingAngle[f] * (1 - unfold))
                let hinge = Pose3(rotation: rotation, translation: folding.hingePoint[f] - rotation.apply(folding.hingePoint[f]))
                expected[f] = expected[folding.parent[f]].concatenating(hinge).concatenating(folding.flat[f])
            }
            for f in 0..<mesh.faceCount {
                let q = mesh.frames[f].localVertices[0]
                #expect((poses[f].apply(q) - expected[f].apply(q)).length < 1e-9)
                #expect((poses[f].rotation.c2 - expected[f].rotation.c2).length < 1e-9)
            }
        }
    }

    @Test func matrixHelpers() {
        let r = Mat3.rotation(axis: .unitZ, angle: .pi / 2)
        #expect((r.apply(.unitX) - .unitY).length < 1e-12)
        let pose = Pose3(rotation: r, translation: Vec3(1, 2, 3))
        let composed = pose.concatenating(pose)
        #expect((composed.apply(Vec3.zero) - pose.apply(pose.apply(Vec3.zero))).length < 1e-12)
    }
}
