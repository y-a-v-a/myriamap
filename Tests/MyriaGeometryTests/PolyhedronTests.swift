import Foundation
import Testing
@testable import MyriaGeometry

@Suite("Polyhedra")
struct PolyhedronTests {
    func assertClosedSphereMesh(_ p: Polyhedron, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let topology = try MeshTopology(p)
        // Euler characteristic of a sphere.
        #expect(p.vertexCount - topology.edgeCount + p.faceCount == 2, sourceLocation: sourceLocation)
        for v in p.vertices {
            #expect(abs(v.length - 1) < 1e-12, sourceLocation: sourceLocation)
        }
        for f in 0..<p.faceCount {
            let verts = p.faceVertices(f)
            let normal = Polyhedron.newellNormal(verts)
            // Counter-clockwise seen from outside.
            #expect(normal.dot(p.faceCenter(f)) > 0, sourceLocation: sourceLocation)
            // Planar faces.
            let frame = FaceFrame(vertices: verts)
            for v in verts {
                #expect(abs(frame.normal.dot(v) - frame.planeDistance) < 1e-9, sourceLocation: sourceLocation)
            }
            #expect(frame.area > 0, sourceLocation: sourceLocation)
        }
    }

    @Test func icosahedronHasExpectedCounts() throws {
        let ico = Polyhedron.icosahedron()
        #expect(ico.vertexCount == 12)
        #expect(ico.faceCount == 20)
        #expect(try MeshTopology(ico).edgeCount == 30)
        try assertClosedSphereMesh(ico)
        // A vertex sits on the north pole.
        #expect(ico.vertices.contains { abs($0.z - 1) < 1e-12 })
    }

    @Test(arguments: [1, 2, 3, 5, 8])
    func geodesicCounts(frequency n: Int) throws {
        let g = Polyhedron.geodesic(frequency: n)
        #expect(g.faceCount == 20 * n * n)
        #expect(g.vertexCount == 10 * n * n + 2)
        try assertClosedSphereMesh(g)
    }

    @Test func graticuleIsClosedAndPlanar() throws {
        let g = Polyhedron.graticule(latitudeStep: 15, longitudeStep: 7.5)
        #expect(g.faceCount == 12 * 48)
        try assertClosedSphereMesh(g)
    }

    @Test func graticuleMeridiansHitNauticalBoundaries() {
        let g = Polyhedron.graticule(latitudeStep: 7.5, longitudeStep: 1.875)
        let longitudes = Set(g.vertices.filter { abs($0.z) < 0.99 }.map { (GeoPoint($0).longitude * 1000).rounded() / 1000 })
        for k in -12..<12 {
            #expect(longitudes.contains(7.5 + 15 * Double(k)))
        }
    }

    @Test func faceAreasSumToSphereArea() {
        // The gnomonic map of all faces covers the sphere, so the spherical
        // areas of the face polygons add up to 4π.
        let g = Polyhedron.geodesic(frequency: 4)
        var total = 0.0
        for f in 0..<g.faceCount {
            let v = g.faceVertices(f)
            total += Spherical.triangleArea(v[0], v[1], v[2])
        }
        #expect(abs(total - 4 * .pi) < 1e-9)
    }
}

@Suite("Vectors and coordinates")
struct CoordinateTests {
    @Test func geoPointRoundTrip() {
        for lat in stride(from: -89.0, through: 89.0, by: 17.0) {
            for lon in stride(from: -179.0, through: 179.0, by: 23.0) {
                let p = GeoPoint(latitude: lat, longitude: lon)
                let q = GeoPoint(p.unitVector)
                #expect(abs(q.latitude - lat) < 1e-9)
                #expect(abs(q.longitude - lon) < 1e-9)
            }
        }
    }

    @Test func tangentFrameIsOrthonormal() {
        let v = GeoPoint(latitude: 30, longitude: 45).unitVector
        let (e, n) = Spherical.tangentFrame(at: v)
        #expect(abs(e.dot(n)) < 1e-12)
        #expect(abs(e.dot(v)) < 1e-12)
        #expect(abs(n.dot(v)) < 1e-12)
        #expect(n.z > 0)
        // Right-handed: east × north points outward.
        #expect(e.cross(n).dot(v) > 0.999)
    }

    @Test func longitudeHelpers() {
        #expect(Spherical.normalizeLongitude(190) == -170)
        #expect(Spherical.normalizeLongitude(-180) == -180)
        #expect(Spherical.longitudeDelta(170, -170) == 20)
        #expect(Spherical.longitudeDelta(-170, 170) == -20)
    }

    @Test func rotationMapsFromOntoTo() {
        let a = GeoPoint(latitude: 10, longitude: 20).unitVector
        let b = GeoPoint(latitude: -40, longitude: 100).unitVector
        let r = Spherical.rotate(a, from: a, to: b)
        #expect((r - b).length < 1e-12)
        let antipode = Spherical.rotate(a, from: a, to: -a)
        #expect((antipode + a).length < 1e-12)
    }

    @Test func rigidMotionInverseAndMatching() {
        let t = Rigid2D(angle: 0.7, translation: Vec2(3, -2))
        let p = Vec2(1.5, 4)
        #expect((t.inverse.apply(t.apply(p)) - p).length < 1e-12)
        let m = Rigid2D.matching(Vec2(0, 0), Vec2(1, 0), to: Vec2(5, 5), Vec2(5, 6))
        #expect((m.apply(Vec2(0, 0)) - Vec2(5, 5)).length < 1e-12)
        #expect((m.apply(Vec2(1, 0)) - Vec2(5, 6)).length < 1e-12)
        let c = t.concatenating(m)
        #expect((c.apply(p) - t.apply(m.apply(p))).length < 1e-12)
    }
}
