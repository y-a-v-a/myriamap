import Foundation
import ImageIO
import Testing
import MyriaGeometry
import ZoneAtlas
@testable import Myriamap

/// Bundled data and a coarse map, shared by the tests (loading takes ~1 s).
enum Fixture {
    static let data = try! GeoData.bundled()
    static let date = ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z")!
    static let base = try! MeshOverlay(kind: .graticule(step: 3.75), data: data)
    static let map = MyriaMap(base: base, data: data, configuration: MapConfiguration(
        mesh: .graticule(step: 3.75), referenceDate: date))
}

@Suite("Face overlay")
struct FaceOverlayTests {
    @Test func zoneFillsTileEveryFace() {
        let mesh = Fixture.base.mesh, overlay = Fixture.base.overlay
        for f in 0..<mesh.faceCount {
            let covered = overlay.zoneFills[f].reduce(0) { $0 + $1.area }
            #expect(abs(covered / mesh.frames[f].area - 1) < 1e-3, "face \(f) covered \(covered / mesh.frames[f].area)")
        }
    }

    @Test func landFillsStayInsideTheirFaces() {
        let mesh = Fixture.base.mesh, overlay = Fixture.base.overlay
        var landArea = 0.0, total = 0.0
        for f in 0..<mesh.faceCount {
            let land = overlay.landFills[f].reduce(0) { $0 + Planar.signedArea($1) }
            #expect(land <= mesh.frames[f].area * (1 + 1e-9))
            #expect(land >= -1e-12)
            landArea += land
            total += mesh.frames[f].area
        }
        // About 29 % of the Earth is land.
        #expect(abs(landArea / total - 0.29) < 0.02)
    }

    @Test func dominantRegionMatchesLookupAtFaceCentres() {
        let mesh = Fixture.base.mesh, overlay = Fixture.base.overlay
        var agree = 0
        for f in 0..<mesh.faceCount {
            let region = Fixture.data.atlas.polygons.feature(at: GeoPoint(mesh.polyhedron.faceCenter(f)))
            if region == overlay.dominantRegion(of: f) { agree += 1 }
        }
        #expect(Double(agree) / Double(mesh.faceCount) > 0.95)
    }

    @Test func linesAreClippedToFaces() {
        let mesh = Fixture.base.mesh, overlay = Fixture.base.overlay
        var count = 0
        for f in 0..<mesh.faceCount {
            for line in overlay.borderLines[f] + overlay.coastLines[f] {
                for p in line {
                    #expect(Planar.convexContains(mesh.frames[f].localVertices, p, tolerance: 1e-9))
                }
                count += 1
            }
        }
        #expect(count > 1000)
    }
}

@Suite("Timezone map")
struct MyriaMapTests {
    @Test func cutsFollowTimezoneBorders() {
        let map = Fixture.map
        var borderEdges = 0, borderHinges = 0
        for (e, edge) in map.mesh.topology.edges.enumerated()
        where map.faceGroups[edge.leftFace] != map.faceGroups[edge.rightFace] {
            borderEdges += 1
            if !map.projection.unfolding.isCut[e] { borderHinges += 1 }
        }
        // Only the joints that hold the pieces together stay uncut.
        #expect(borderEdges > 500)
        #expect(Double(borderHinges) / Double(borderEdges) < 0.1)
    }

    @Test func everyZoneHangsTogetherInFewPieces() {
        let map = Fixture.map
        let pieces = map.pieces()
        let groupsWithFaces = Set(map.faceGroups.filter { $0 >= 0 })
        #expect(pieces.count >= groupsWithFaces.count)
        // Each piece is one zone.
        for piece in pieces { #expect(Set(piece.map { map.faceGroups[$0] }).count == 1) }
    }

    @Test func overlapsAreRare() {
        let report = MapReport(map: Fixture.map)
        #expect(report.overlapFraction < 0.01)
    }

    @Test func labelsShowTheRightRegion() throws {
        let map = Fixture.map
        #expect(map.labels.count > 30)
        for label in map.labels where label.room > 0.08 {
            let hit = try #require(map.region(atMapPoint: label.position))
            #expect(map.grouping.groupOfRegion[hit.region.id] == label.group)
        }
        let paris = try #require(map.atlas.region(named: "Europe/Paris"))
        let parisLabel = try #require(map.labels.first { $0.region == paris.id })
        let location = try #require(map.projection.inverse(parisLabel.position)).point
        // Placed over Europe, not in some far corner of the zone.
        #expect(location.latitude > 35 && location.latitude < 60)
        #expect(location.longitude > -5 && location.longitude < 25)
    }

    @Test func aucklandsClockIsOnNewZealandNotAntarctica() throws {
        let map = Fixture.map
        let auckland = try #require(map.atlas.region(named: "Pacific/Auckland"))
        let label = try #require(map.labels.first { $0.region == auckland.id })
        let location = try #require(map.projection.inverse(label.position)).point
        #expect(location.latitude > -50)
    }

    @Test func mapIsNorthUpAtTheCentre() {
        let map = Fixture.map
        let south = map.projection.project(GeoPoint(latitude: -5, longitude: 10))
        let north = map.projection.project(GeoPoint(latitude: 5, longitude: 10))
        #expect(north.y > south.y)
        #expect(abs(north.x - south.x) < 0.02)
    }

    @Test func utcOffsetGroupingMergesRegionsWithTheSameOffset() {
        let grouping = ZoneGrouping(atlas: Fixture.data.atlas, grouping: .utcOffset, date: Fixture.date)
        #expect(grouping.groups.count < Fixture.data.atlas.regions.count)
        for region in Fixture.data.atlas.regions {
            let g = grouping.groups[grouping.groupOfRegion[region.id]]
            #expect(g.utcOffset == region.utcOffset(at: Fixture.date))
            #expect(g.regions.contains(region.id))
        }
        let map = MyriaMap(base: Fixture.base, data: Fixture.data, configuration: MapConfiguration(
            mesh: .graticule(step: 3.75), grouping: .utcOffset, referenceDate: Fixture.date))
        #expect(map.projection.unfolding.order.count == map.mesh.faceCount)
        #expect(map.labels.count <= grouping.groups.count)
    }

    @Test func offsetGroupLabelsNameTheRegionBeneathThem() throws {
        let map = MyriaMap(base: Fixture.base, data: Fixture.data, configuration: MapConfiguration(
            mesh: .graticule(step: 3.75), grouping: .utcOffset,
            referenceDate: ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!))
        var matches = 0, total = 0
        for label in map.labels where label.room > 0.08 {
            let hit = try #require(map.region(atMapPoint: label.position))
            total += 1
            if hit.region.id == label.region { matches += 1 }
        }
        #expect(total > 10)
        #expect(Double(matches) / Double(total) > 0.9)
    }

    @Test func landmassCutsBuildToo() {
        let map = MyriaMap(base: Fixture.base, data: Fixture.data, configuration: MapConfiguration(
            mesh: .graticule(step: 3.75), cuts: .landmass, referenceDate: Fixture.date))
        #expect(map.projection.unfolding.cutCount == map.mesh.polyhedron.vertexCount - 1)
    }

    @Test func meshArgumentsRoundTrip() {
        for kind in [MeshKind.graticule(step: 1.875), .geodesic(frequency: 32), .graticule(step: 5)] {
            #expect(MeshKind(argument: kind.argument) == kind)
        }
        #expect(MeshKind(argument: "cube:3") == nil)
        #expect(MeshKind(argument: "geodesic:0") == nil)
    }
}

@Suite("Rendering")
struct RenderingTests {
    @Test func sceneContainsEveryLayer() {
        var options = SceneOptions(date: Fixture.date)
        options.showCuts = true
        options.showMesh = true
        options.highlightGroup = 0
        let scene = Fixture.map.scene(options)
        let roles = Set(scene.paths.map(\.role))
        for role in [ScenePath.Role.zone, .land, .night, .coastline, .border, .cut, .mesh, .highlight] {
            #expect(roles.contains(role), "missing \(role)")
        }
        #expect(!scene.texts.isEmpty)
        // Clock labels show times at the scene's date.
        #expect(scene.texts.contains { $0.text == "14:00" })  // Paris, CEST
    }

    @Test func neighbouringZonesGetDifferentColours() {
        let map = Fixture.map
        let slots = map.groupColorSlots(slotCount: 5)
        for edge in map.mesh.topology.edges {
            let a = map.faceGroups[edge.leftFace], b = map.faceGroups[edge.rightFace]
            if a >= 0, b >= 0, a != b { #expect(slots[a] != slots[b]) }
        }
    }

    @Test func nightCoversTheSideAwayFromTheSun() {
        let scene = Fixture.map.scene(SceneOptions(date: Fixture.date))
        let night = scene.paths.first { $0.role == .night }!
        let area = night.subpaths.reduce(0) { $0 + Planar.signedArea($1) }
        let total = Fixture.map.projection.mapPolygons.reduce(0) { $0 + Planar.signedArea($1) }
        // Half the globe is in night (including refraction-free geometry).
        #expect(abs(area / total - 0.5) < 0.03)
    }

    @Test func svgIsWellFormed() throws {
        let svg = SVGRenderer.render(Fixture.map.scene(SceneOptions(date: Fixture.date)), width: 800, title: "Test & <map>")
        #expect(svg.hasPrefix("<svg"))
        #expect(svg.hasSuffix("</svg>\n"))
        #expect(svg.contains("<title>Test &amp; &lt;map&gt;</title>"))
        #expect(svg.contains("class=\"zone\""))
        let doc = try XMLDocument(xmlString: svg)
        #expect(doc.rootElement()?.name == "svg")
    }

    @Test func pngHasTheRequestedSize() throws {
        let png = try BitmapRenderer.png(Fixture.map.scene(SceneOptions(date: Fixture.date)), width: 400)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let image = try BitmapRenderer.image(Fixture.map.scene(SceneOptions(date: Fixture.date)), width: 400)
        #expect(image.width == 400)
        #expect(image.height > 150 && image.height < 300)
    }

    @Test func canvasMappingRoundTrips() {
        let m = CanvasMapping(bounds: Rect2(minX: -3, minY: -1.5, maxX: 3, maxY: 1.5), width: 616)
        let p = Vec2(1.25, -0.5)
        #expect((m.invert(m.apply(p)) - p).length < 1e-12)
        // y points down on the canvas.
        #expect(m.apply(Vec2(0, 1)).y < m.apply(Vec2(0, -1)).y)
    }
}

@Suite("Viewport")
struct ViewportTests {
    let bounds = Rect2(minX: -3, minY: -1.5, maxX: 3, maxY: 1.5)

    @Test func fitsAndRoundTrips() {
        let v = Viewport(bounds: bounds, size: Vec2(624, 400), margin: 12)
        #expect(abs(v.scale - 100) < 1e-9)
        let p = Vec2(1.5, -0.25)
        #expect((v.toMap(v.toView(p)) - p).length < 1e-12)
        #expect((v.toView(bounds.center) - Vec2(312, 200)).length < 1e-9)
        #expect(v.toView(Vec2(0, 1)).y < v.toView(Vec2(0, -1)).y)
    }

    @Test func zoomKeepsTheAnchorFixed() {
        var v = Viewport(bounds: bounds, size: Vec2(624, 400))
        let anchor = Vec2(500, 120)
        let before = v.toMap(anchor)
        v.zoom(by: 3, around: anchor)
        #expect(abs(v.zoom - 3) < 1e-12)
        #expect((v.toMap(anchor) - before).length < 1e-9)
        v.zoom(by: 0.01, around: anchor)
        #expect(v.zoom == 1)
    }

    @Test func panMovesWithTheDrag() {
        var v = Viewport(bounds: bounds, size: Vec2(624, 400), zoom: 2)
        let p = Vec2(0.5, 0.5)
        let before = v.toView(p)
        v.pan(by: Vec2(30, -10))
        #expect((v.toView(p) - (before + Vec2(30, -10))).length < 1e-9)
    }
}

@Suite("Folded scenes")
struct FoldedSceneTests {
    static let folding = Fixture.map.folding()

    func zoneArea(_ scene: MapScene) -> Double {
        scene.paths.filter { $0.role == .zone }.reduce(0) { total, path in
            total + path.subpaths.reduce(0) { $0 + Planar.signedArea($1) }
        }
    }

    @Test func flatFoldMatchesTheMap() {
        let options = SceneOptions(date: Fixture.date)
        let folded = Fixture.map.foldedScene(unfold: 1, folding: Self.folding, options: options)
        let flat = Fixture.map.scene(options)
        #expect(abs(zoneArea(folded) / zoneArea(flat) - 1) < 1e-9)
    }

    @Test func closedFoldIsAGlobeAtTheOrigin() {
        let scene = Fixture.map.foldedScene(unfold: 0, folding: Self.folding, options: SceneOptions(date: Fixture.date))
        for path in scene.paths {
            for ring in path.subpaths {
                for p in ring { #expect(p.length < 1.05) }
            }
        }
        #expect(scene.bounds.contains(Vec2(1, 1)))
        // Batched per depth bucket and colour, not per face.
        #expect(scene.paths.count < Fixture.map.mesh.faceCount / 4)
    }

    @Test func gifEncodesEveryFrame() throws {
        let options = SceneOptions(date: Fixture.date)
        let scenes = [0.0, 0.5, 1.0].map { Fixture.map.foldedScene(unfold: $0, folding: Self.folding, options: options) }
        let gif = try BitmapRenderer.gif(scenes, delays: [0.1, 0.1, 0.1], width: 200)
        #expect(gif.starts(with: Array("GIF8".utf8)))
        let source = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 3)
    }
}
