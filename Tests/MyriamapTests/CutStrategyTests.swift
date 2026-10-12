import Foundation
import Testing
import MyriaGeometry
@testable import Myriamap

/// Synthetic zones: the 24 nautical lunes (15° wide, centred on multiples of 15°).
func nauticalLune(_ p: GeoPoint) -> Int {
    ((Int(((p.longitude + 7.5) / 15).rounded(.down)) % 24) + 24) % 24
}

@Suite("Timezone cuts on synthetic lunes")
struct SyntheticCutTests {
    static let mesh = try! MyriahedralMesh(.graticule(latitudeStep: 3.75, longitudeStep: 3.75))
    static let groups = (0..<mesh.faceCount).map { nauticalLune(GeoPoint(mesh.polyhedron.faceCenter($0))) }

    static func hinges(center: Double) -> [Bool] {
        let root = mesh.face(containing: GeoPoint(latitude: 0, longitude: center).unitVector)
        return TimeZoneCutStrategy(centerLongitude: center).hinges(mesh: mesh, faceGroups: groups, root: root)
    }

    @Test func hingesFormASpanningTree() {
        let hinges = Self.hinges(center: 0)
        #expect(hinges.filter { $0 }.count == Self.mesh.faceCount - 1)
        // Unfolding asserts that the hinges reach every face.
        let map = MyriahedralProjection(mesh: Self.mesh, hinges: hinges, root: 0)
        #expect(map.unfolding.order.count == Self.mesh.faceCount)
    }

    @Test func lunesAreCutApartExceptAtTheEquator() {
        let hinges = Self.hinges(center: 0)
        var crossings: [Int: [Double]] = [:]  // west lune → latitudes of hinges to its east neighbour
        for (e, edge) in Self.mesh.topology.edges.enumerated() where hinges[e] {
            let a = Self.groups[edge.leftFace], b = Self.groups[edge.rightFace]
            guard a != b else { continue }
            let mid = GeoPoint((Self.mesh.polyhedron.vertices[edge.a] + Self.mesh.polyhedron.vertices[edge.b]).normalized)
            let west = (b - a + 24) % 24 == 1 ? a : b
            crossings[west, default: []].append(mid.latitude)
        }
        // 24 lunes in a belt need 23 joints: one between every pair of
        // neighbours except one, and every joint sits at the equator.
        #expect(crossings.values.map(\.count).reduce(0, +) == 23)
        for latitudes in crossings.values {
            #expect(latitudes.count == 1)
            #expect(abs(latitudes[0]) < 4)
        }
        // The belt opens on the far side from the centre: between the lunes
        // at 165°E and 180°.
        #expect(crossings[11] == nil)
    }

    @Test func beltOpensOppositeTheChosenCentre() {
        let hinges = Self.hinges(center: 90)
        var joined = Set<Int>()
        for (e, edge) in Self.mesh.topology.edges.enumerated() where hinges[e] {
            let a = Self.groups[edge.leftFace], b = Self.groups[edge.rightFace]
            if a != b { joined.insert((b - a + 24) % 24 == 1 ? a : b) }
        }
        let open = (0..<24).filter { !joined.contains($0) }
        #expect(open.count == 1)
        // Lune 18 is centred on 90°W (270°E): the antipode of 90°E.
        #expect(open.allSatisfy { abs($0 - 18) <= 1 })
    }

    @Test func eachLuneIsOneUprightPiece() {
        let hinges = Self.hinges(center: 0)
        let pieces = PieceRotations(mesh: Self.mesh, hinges: hinges.indices.map { e in
            let edge = Self.mesh.topology.edges[e]
            return hinges[e] && Self.groups[edge.leftFace] == Self.groups[edge.rightFace]
        })
        #expect(pieces.count == 24)
        let map = MyriahedralProjection(mesh: Self.mesh, hinges: hinges, root: 0)
        for members in pieces.faces {
            var s = 0.0, c = 0.0
            for f in members {
                s += sin(map.unfolding.transforms[f].angle)
                c += cos(map.unfolding.transforms[f].angle)
            }
            // Mean orientation of every lune is close to north-up.
            #expect(abs(atan2(s, c)) < 0.1)
        }
    }

    @Test func internalSlitsRunAlongParallels() {
        // Inside a lune the cut edges are parallels (crossed north–south);
        // meridian edges inside a lune stay hinged.
        let hinges = Self.hinges(center: 0)
        var cutParallels = 0, cutMeridians = 0
        let centers = (0..<Self.mesh.faceCount).map { Self.mesh.polyhedron.faceCenter($0) }
        for (e, edge) in Self.mesh.topology.edges.enumerated()
        where !hinges[e] && Self.groups[edge.leftFace] == Self.groups[edge.rightFace] {
            let g = EdgeGeometry(edge: edge, mesh: Self.mesh, centers: centers)
            if g.eastWestness > 0.5 { cutMeridians += 1 } else { cutParallels += 1 }
        }
        #expect(cutParallels > 10 * max(cutMeridians, 1))
    }

    @Test func landmassStrategyAlsoYieldsATree() {
        let land = (0..<Self.mesh.faceCount).map { abs(GeoPoint(Self.mesh.polyhedron.faceCenter($0)).latitude) < 30 ? 1 : 0 }
        let hinges = LandmassCutStrategy().hinges(mesh: Self.mesh, faceGroups: land, root: 0)
        #expect(hinges.filter { $0 }.count == Self.mesh.faceCount - 1)
    }

    @Test func polarCapsWrappingThePoleAreSplitIntoSectors() {
        // One group covering everything south of 60°S, lunes elsewhere.
        let groups = (0..<Self.mesh.faceCount).map { f -> Int in
            let p = GeoPoint(Self.mesh.polyhedron.faceCenter(f))
            return p.latitude < -60 ? 24 : nauticalLune(p)
        }
        let split = MyriaMap.splittingPolarCaps(groups, mesh: Self.mesh, groupCount: 25)
        let capGroups = Set((0..<Self.mesh.faceCount).filter { groups[$0] == 24 }.map { split[$0] })
        #expect(capGroups.count == 24)
        // Faces outside the cap keep their group.
        for f in 0..<Self.mesh.faceCount where groups[f] != 24 { #expect(split[f] == groups[f]) }
    }
}
