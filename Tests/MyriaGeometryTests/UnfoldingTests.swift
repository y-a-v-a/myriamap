import Foundation
import Testing
@testable import MyriaGeometry

@Suite("Spanning trees")
struct SpanningTreeTests {
    @Test func keepsHeaviestAcyclicEdges() {
        // Square with a diagonal: 0-1, 1-2, 2-3, 3-0, 0-2.
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (0, 2)]
        let weights = [5.0, 1.0, 4.0, 3.0, 2.0]
        let tree = SpanningTree.maximum(nodeCount: 4, edges: edges, weights: weights)
        #expect(tree == [true, false, true, true, false])
    }

    @Test func unionFindCountsComponents() {
        var uf = UnionFind(count: 5)
        let merged = [uf.union(0, 1), uf.union(3, 4), uf.union(1, 0)]
        #expect(merged == [true, true, false])
        #expect(uf.componentCount == 3)
        let roots = (0..<5).map { uf.find($0) }
        #expect(roots[0] == roots[1])
        #expect(roots[2] != roots[3])
    }
}

@Suite("Unfolding")
struct UnfoldingTests {
    static func pseudoRandomWeights(_ count: Int, seed: UInt64 = 42) -> [Double] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static let meshes: [(String, Polyhedron)] = [
        ("geodesic", .geodesic(frequency: 6)),
        ("graticule", .graticule(latitudeStep: 10, longitudeStep: 7.5)),
    ]

    @Test(arguments: [0, 1])
    func hingesStayAttachedAndFacesKeepTheirShape(meshIndex: Int) throws {
        let mesh = try MyriahedralMesh(Self.meshes[meshIndex].1)
        let weights = Self.pseudoRandomWeights(mesh.topology.edgeCount)
        let map = mesh.unfold(weights: weights, root: 0)

        // A spanning tree of F faces has F - 1 hinges; the cuts form a
        // spanning tree of the V vertices.
        #expect(map.unfolding.cutCount == mesh.polyhedron.vertexCount - 1)
        #expect(map.unfolding.order.count == mesh.faceCount)

        for (e, edge) in mesh.topology.edges.enumerated() where !map.unfolding.isCut[e] {
            let segments = map.mapSegments(ofEdge: e)
            #expect((segments[0].0 - segments[1].0).length < 1e-9)
            #expect((segments[0].1 - segments[1].1).length < 1e-9)
            _ = edge
        }
        for f in 0..<mesh.faceCount {
            let local = mesh.frames[f].localVertices
            let mapped = map.mapPolygons[f]
            // Rigid motion: same area and orientation, same edge lengths.
            #expect(abs(Planar.signedArea(mapped) - Planar.signedArea(local)) < 1e-12)
            for i in local.indices {
                let j = (i + 1) % local.count
                #expect(abs((mapped[i] - mapped[j]).length - (local[i] - local[j]).length) < 1e-12)
            }
        }
    }

    @Test func everyVertexTouchesACut() throws {
        // Positive angular defect at every vertex means no vertex can be
        // surrounded by hinges only.
        let mesh = try MyriahedralMesh(.geodesic(frequency: 5))
        let map = mesh.unfold(weights: Self.pseudoRandomWeights(mesh.topology.edgeCount, seed: 7), root: 3)
        for v in 0..<mesh.polyhedron.vertexCount {
            #expect(mesh.topology.vertexEdges[v].contains { map.unfolding.isCut[$0] })
        }
    }

    @Test func rootFaceIsNorthUp() throws {
        let mesh = try MyriahedralMesh(.graticule(latitudeStep: 10, longitudeStep: 10))
        let root = mesh.face(containing: GeoPoint(latitude: 5, longitude: 5).unitVector)
        let map = mesh.unfold(weights: Array(repeating: 1, count: mesh.topology.edgeCount), root: root)
        let south = map.project(GeoPoint(latitude: 1, longitude: 5))
        let north = map.project(GeoPoint(latitude: 9, longitude: 5))
        let west = map.project(GeoPoint(latitude: 5, longitude: 1))
        let east = map.project(GeoPoint(latitude: 5, longitude: 9))
        #expect(north.y > south.y)
        #expect(abs(north.x - south.x) < 1e-3)
        #expect(east.x > west.x)
    }
}

@Suite("Projection")
struct ProjectionTests {
    @Test func locatorAgreesWithBruteForce() throws {
        let mesh = try MyriahedralMesh(.geodesic(frequency: 7))
        let weights = UnfoldingTests.pseudoRandomWeights(1000, seed: 3)
        for i in stride(from: 0, to: 1000, by: 2) {
            let lat = asin(2 * weights[i] - 1) * 180 / .pi
            let lon = weights[i + 1] * 360 - 180
            let v = GeoPoint(latitude: lat, longitude: lon).unitVector
            let f = mesh.face(containing: v)
            #expect(mesh.locator.insideness(f, v) >= -1e-12)
        }
    }

    @Test func projectsIntoTheContainingFaceAndInvertsBack() throws {
        let mesh = try MyriahedralMesh(.graticule(latitudeStep: 6, longitudeStep: 7.5))
        let map = mesh.unfold(weights: UnfoldingTests.pseudoRandomWeights(mesh.topology.edgeCount), root: 10)
        for lat in stride(from: -85.0, through: 85.0, by: 12.3) {
            for lon in stride(from: -177.0, through: 177.0, by: 19.1) {
                let p = GeoPoint(latitude: lat, longitude: lon)
                let (face, q) = map.project(p.unitVector)
                #expect(Planar.convexContains(map.mapPolygons[face], q, tolerance: 1e-9))
                let back = try #require(map.inverse(q))
                #expect(back.point.distance(to: p) < 1e-9)
            }
        }
    }

    @Test func faceVerticesProjectOntoMapCorners() throws {
        let mesh = try MyriahedralMesh(.geodesic(frequency: 3))
        let map = mesh.unfold(weights: UnfoldingTests.pseudoRandomWeights(mesh.topology.edgeCount), root: 0)
        for f in 0..<mesh.faceCount {
            for (i, v) in mesh.polyhedron.faces[f].enumerated() {
                let q = try #require(map.project(mesh.polyhedron.vertices[v], through: f))
                #expect((q - map.mapPolygons[f][i]).length < 1e-12)
            }
        }
    }
}

@Suite("Clipping")
struct ClippingTests {
    let square = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)]

    @Test func clipsOverlappingSquares() {
        let shifted = square.map { $0 + Vec2(0.5, 0.5) }
        let result = Planar.clip(shifted, toConvex: square)
        #expect(abs(Planar.signedArea(result) - 0.25) < 1e-12)
    }

    @Test func clipsConcavePolygonPreservingArea() {
        // A "U" shape crossing the clip square.
        let u = [Vec2(-1, -1), Vec2(2, -1), Vec2(2, 2), Vec2(0.75, 2), Vec2(0.75, 0.5), Vec2(0.25, 0.5), Vec2(0.25, 2), Vec2(-1, 2)]
        let result = Planar.clip(u, toConvex: square)
        #expect(abs(Planar.signedArea(result) - (1 - 0.5 * 0.5)) < 1e-12)
    }

    @Test func clipsSegments() throws {
        let s = try #require(Planar.clipSegment(Vec2(-1, 0.5), Vec2(2, 0.5), toConvex: square))
        #expect((s.0 - Vec2(0, 0.5)).length < 1e-12)
        #expect((s.1 - Vec2(1, 0.5)).length < 1e-12)
        #expect(Planar.clipSegment(Vec2(-1, 2), Vec2(2, 2), toConvex: square) == nil)
    }

    @Test func pointInPolygon() {
        #expect(Planar.contains(square, Vec2(0.5, 0.5)))
        #expect(!Planar.contains(square, Vec2(1.5, 0.5)))
        #expect(Planar.convexContains(square, Vec2(1, 0.5)))
    }

    @Test func halfPlaneClipByValues() {
        let r = Planar.clip(square, values: square.map { 0.5 - $0.x })
        #expect(abs(Planar.signedArea(r) - 0.5) < 1e-12)
    }

    @Test func sphericalCapClipKeepsPointsOnArcs() {
        let ring = [GeoPoint(latitude: 0, longitude: -60), GeoPoint(latitude: 0, longitude: 60),
                    GeoPoint(latitude: 60, longitude: 0)].map(\.unitVector)
        let axis = GeoPoint(latitude: 0, longitude: 50).unitVector
        let clipped = SphericalClip.clipRing(ring, axis: axis, minimumCosine: 0.5)
        #expect(clipped.count >= 3)
        for p in clipped {
            #expect(axis.dot(p) >= 0.5 - 1e-12)
            #expect(abs(p.length - 1) < 1e-12)
        }
    }
}
