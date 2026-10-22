import CoreGraphics
import Foundation
import Metal
import Testing
import MyriaGeometry
@testable import Myriamap

/// The fixture's geometry, as the GPU gets it.
enum RenderFixture {
    static let mesh = RenderMesh(Fixture.base)
}

@Suite("GPU geometry")
struct RenderMeshTests {
    /// Area per face of indexed triangles.
    static func areas(_ vertices: [FillVertex], _ indices: [UInt32], faces: Int) -> [Double] {
        var areas = Array(repeating: 0.0, count: faces)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = vertices[Int(indices[i])], b = vertices[Int(indices[i + 1])], c = vertices[Int(indices[i + 2])]
            #expect(a.face == b.face && b.face == c.face && a.region == b.region && b.region == c.region)
            areas[Int(a.face)] += Double((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        }
        return areas
    }

    @Test func trianglesCoverTheFills() {
        let mesh = Fixture.base.mesh, overlay = Fixture.base.overlay, render = RenderFixture.mesh
        #expect(render.zoneIndices.count % 3 == 0 && render.landIndices.count % 3 == 0)
        let zones = Self.areas(render.zoneVertices, render.zoneIndices, faces: mesh.faceCount)
        let land = Self.areas(render.landVertices, render.landIndices, faces: mesh.faceCount)
        for f in 0..<mesh.faceCount {
            // Triangles fill by the nonzero rule, like the renderers; the
            // overlay's areas are signed sums, which differ only for stray
            // hole rings, so allow a little.
            let face = mesh.frames[f].area
            #expect(abs(zones[f] - face) < 2e-3 * face, "face \(f): zones \(zones[f] / face)")
            let expected = overlay.landFills[f].reduce(0) { $0 + Planar.signedArea($1) }
            #expect(abs(land[f] - expected) < 2e-3 * face, "face \(f): land \(land[f] / face) vs \(expected / face)")
        }
    }

    @Test func triangleRegionsMatchTheirFills() {
        let overlay = Fixture.base.overlay
        // Shared corners: noticeably fewer corners than triangle vertices.
        #expect(RenderFixture.mesh.zoneVertices.count * 3 < RenderFixture.mesh.zoneIndices.count * 2)
        for v in RenderFixture.mesh.zoneVertices {
            #expect(overlay.zoneFills[Int(v.face)].contains { $0.region == Int(v.region) })
        }
    }

    @Test func outlinesKnowTheEdgeTheyRunAlong() {
        let mesh = Fixture.base.mesh, render = RenderFixture.mesh
        #expect(render.zoneOutlineEdges.count == render.zoneOutlines.count)
        var alongEdges = 0
        for (s, e) in zip(render.zoneOutlines, render.zoneOutlineEdges) {
            let f = Int(s.face)
            guard e >= 0 else { continue }
            alongEdges += 1
            let i = mesh.topology.faceEdges[f].firstIndex(of: Int(e))!
            let polygon = mesh.frames[f].localVertices
            let p = polygon[i], d = polygon[(i + 1) % polygon.count] - p
            for q in [Vec2(Double(s.ax), Double(s.ay)), Vec2(Double(s.bx), Double(s.by))] {
                #expect(abs(d.cross(q - p)) / d.length < 1e-6 * d.length)
            }
        }
        // At least every side of every fill that covers its whole face.
        let wholeFaces = (0..<mesh.faceCount).reduce(0) { sum, f in
            sum + Fixture.base.overlay.zoneFills[f].filter { $0.rings == [mesh.frames[f].localVertices] }.count
        }
        #expect(wholeFaces > mesh.faceCount / 2)
        #expect(alongEdges >= 4 * wholeFaces)
    }

    @Test func faceRangesHoldEachFacesPart() {
        let render = RenderFixture.mesh
        for f in stride(from: 0, to: render.faceCount, by: 13) {
            for i in render.zoneIndexRanges.range(of: f) { #expect(render.zoneVertices[Int(render.zoneIndices[i])].face == f) }
            for i in render.zoneOutlineRanges.range(of: f) { #expect(render.zoneOutlines[i].face == f) }
            for i in render.coastlineRanges.range(of: f) { #expect(render.coastlines[i].face == f) }
            for i in render.faceEdgeRanges.range(of: f) { #expect(render.faceEdges[i].face == f) }
        }
    }

    @Test func cellsRegroupEverythingOnce() {
        let map = Fixture.map, render = RenderFixture.mesh
        let cells = MapCells(map: map, mesh: render)
        #expect(cells.zoneIndices.count == render.zoneIndices.count)
        #expect(cells.landIndices.count == render.landIndices.count)
        #expect(cells.coastlines.count == render.coastlines.count)
        #expect(cells.borders.count == render.borders.count)
        #expect(cells.faceEdges.count == render.faceEdges.count)
        #expect(Set(cells.zoneIndices) == Set(render.zoneIndices))
        // Seals: the outline segments along cut edges.
        let isCut = map.projection.unfolding.isCut
        #expect(cells.seals.count == render.zoneOutlineEdges.filter { $0 >= 0 && isCut[Int($0)] }.count)
        #expect(cells.runs(overlapping: map.projection.bounds) == cells.all)
    }

    @Test func cullingKeepsEveryFaceInView() {
        let map = Fixture.map, cells = MapCells(map: map, mesh: RenderFixture.mesh)
        let polygons = map.projection.mapPolygons, b = map.projection.bounds
        var drawnFaces: Set<UInt32> = []
        for (i, (x, y, w)) in [(0.3, 0.5, 0.1), (0.8, 0.2, 0.05), (0.05, 0.9, 0.2), (0.5, 0.5, 0.01)].enumerated() {
            let center = Vec2(b.minX + x * b.width, b.minY + y * b.height), half = w * b.width
            let view = Rect2(minX: center.x - half, minY: center.y - half / 2, maxX: center.x + half, maxY: center.y + half / 2)
            let runs = cells.runs(overlapping: view)
            #expect(!runs.isEmpty)
            drawnFaces = []
            for run in runs {
                for j in cells.span(run, \.faceEdges) { drawnFaces.insert(cells.faceEdges[j].face) }
            }
            for f in polygons.indices where Rect2(bounding: polygons[f]).intersects(view) {
                #expect(drawnFaces.contains(UInt32(f)), "view \(i): face \(f) culled")
            }
            // A small view draws a small part.
            if w <= 0.05 { #expect(drawnFaces.count < polygons.count / 4) }
        }
    }

    @Test func flatTransformsPlaceFacesOnTheMap() {
        let map = Fixture.map, transforms = map.flatFaceTransforms()
        #expect(transforms.count == map.mesh.faceCount + 1)
        #expect(transforms.last == .identity)
        for f in stride(from: 0, to: map.mesh.faceCount, by: 7) {
            for (q, expected) in zip(map.mesh.frames[f].localVertices, map.projection.mapPolygons[f]) {
                let t = transforms[f]
                let x = Double(t.x.x) * q.x + Double(t.x.y) * q.y + Double(t.x.w)
                let y = Double(t.y.x) * q.x + Double(t.y.y) * q.y + Double(t.y.w)
                #expect((Vec2(x, y) - expected).length < 1e-5)
            }
        }
    }

    @Test func foldedTransformsFollowTheFolding() {
        let map = Fixture.map, folding = map.folding()
        let transforms = map.foldedFaceTransforms(unfold: 0.4, folding: folding)
        let camera = FoldCamera(unfold: 0.4, tilt: 0.35).pose
        let poses = folding.poses(unfold: 0.4)
        for f in stride(from: 0, to: map.mesh.faceCount, by: 11) {
            let q = map.mesh.frames[f].localVertices[1]
            let expected = camera.apply(poses[f].apply(q))
            let t = transforms[f]
            let p = Vec3(Double(t.x.x) * q.x + Double(t.x.y) * q.y + Double(t.x.w),
                         Double(t.y.x) * q.x + Double(t.y.y) * q.y + Double(t.y.w),
                         Double(t.z.x) * q.x + Double(t.z.y) * q.y + Double(t.z.w))
            #expect((p - expected).length < 1e-5)
        }
    }
}

@Suite("Metal renderer", .serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalRendererTests {
    static let renderer = try! MetalMapRenderer()
    static let map = try! renderer.makeMap(Fixture.map, mesh: renderer.makeMesh(RenderFixture.mesh, kind: Fixture.base.kind))

    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// Renders with Metal and with Core Graphics at the same size, and
    /// returns the mean difference (0...255) and the share of pixels that
    /// differ by more than 40.
    static func compare(style: MapStyle, unfold: Double = 1, night: Bool = true, width: Int = 1200,
                        window: Rect2? = nil) throws -> (mean: Double, far: Double) {
        let map = Fixture.map
        var options = SceneOptions(date: Fixture.date, style: style)
        options.showLabels = false
        options.showNight = night
        var scene = unfold < 1 ? map.foldedScene(unfold: unfold, folding: map.folding(), options: options) : map.scene(options)
        if let window { scene.bounds = window }
        let reference = try BitmapRenderer.image(scene, width: width)
        var frame = MapFrame(viewport: Viewport(bounds: window ?? map.projection.bounds,
                                                size: Vec2(Double(width), Double(reference.height)), margin: 16),
                             contentsScale: 1, date: Fixture.date, style: style)
        frame.unfold = unfold
        frame.showNight = night
        let image = try renderer.image(frame, map: Self.map, width: width, height: reference.height)
        let a = pixels(image), b = pixels(reference)
        var total = 0, far = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let d = (0..<3).map { abs(Int(a[i + $0]) - Int(b[i + $0])) }.max()!
            total += d
            if d > 40 { far += 1 }
        }
        let n = Double(a.count / 4)
        return (Double(total) / n, Double(far) / n)
    }

    @Test(arguments: [false, true])
    func flatMapMatchesCoreGraphics(dark: Bool) throws {
        let (mean, far) = try Self.compare(style: dark ? .dark : .light)
        // Antialiasing differs along lines; the rest agrees.
        #expect(mean < 4, "mean difference \(mean)")
        #expect(far < 0.02, "\(far * 100)% of pixels differ")
    }

    @Test func zoomedViewMatchesCoreGraphics() throws {
        // Europe and Africa, a twentieth of the map's width: most cells are culled.
        let window = Rect2(minX: -0.1, minY: 0.2, maxX: 0.22, maxY: 0.6)
        let (mean, far) = try Self.compare(style: .light, window: window)
        #expect(mean < 4, "mean difference \(mean)")
        #expect(far < 0.03, "\(far * 100)% of pixels differ")
    }

    /// Single pixels of page colour inside the map: samples falling
    /// through hairline cracks between triangles.
    static func cracks(unfold: Double, zoom: Double) throws -> Int {
        let map = Fixture.map
        var style = MapStyle.light
        style.page = RGBA(1, 0, 1)
        var frame = MapFrame(viewport: Viewport(bounds: map.projection.bounds, size: Vec2(1400, 720), zoom: zoom,
                                                center: Vec2(0.3, 0.4)),
                             contentsScale: 2, date: Fixture.date, style: style)
        frame.unfold = unfold
        frame.showNight = false
        frame.showCoastlines = false
        frame.showBorders = false
        let image = try renderer.image(frame, map: Self.map, width: 2800, height: 1440)
        let px = pixels(image), w = image.width
        func magenta(_ i: Int) -> Double { max(0, (Double(min(px[i], px[i + 2])) - Double(px[i + 1])) / 255) }
        var isolated = 0
        for y in 1..<(image.height - 1) {
            for x in 1..<(w - 1) {
                let i = (y * w + x) * 4
                if magenta(i) > 0.08, [i - 4, i + 4, i - 4 * w, i + 4 * w].allSatisfy({ magenta($0) < 0.04 }) { isolated += 1 }
            }
        }
        return isolated
    }

    @Test(arguments: [(1.0, 1.0), (1.0, 6.0), (0.0, 1.0)])
    func noCracksBetweenTriangles(unfold: Double, zoom: Double) throws {
        // A few remain where slits taper below a pixel, as with any
        // renderer; without the underlay there are about a hundred.
        let count = try Self.cracks(unfold: unfold, zoom: zoom)
        #expect(count < 40, "\(count) cracks")
    }

    @Test func nightIsDrawnPerPixel() throws {
        let day = try Self.compare(style: .light, night: false)
        let night = try Self.compare(style: .light, night: true)
        #expect(night.mean < day.mean + 1, "night \(night.mean) vs day \(day.mean)")
    }

    @Test func foldedGlobeMatchesCoreGraphics() throws {
        let (mean, far) = try Self.compare(style: .light, unfold: 0.4)
        #expect(mean < 3, "mean difference \(mean)")
        #expect(far < 0.02, "\(far * 100)% of pixels differ")
    }

    @Test func labelsAreDrawn() throws {
        let map = Fixture.map
        var frame = MapFrame(viewport: Viewport(bounds: map.projection.bounds, size: Vec2(1200, 640)),
                             contentsScale: 2, date: Fixture.date, style: .light)
        frame.showNight = false
        let plain = Self.pixels(try Self.renderer.image(frame, map: Self.map, width: 2400, height: 1280))
        frame.labels = map.labelTexts(SceneOptions(date: Fixture.date, style: .light))
        let labelled = Self.pixels(try Self.renderer.image(frame, map: Self.map, width: 2400, height: 1280))
        // Dark ink on light fills: some pixels get much darker.
        let darkened = stride(from: 0, to: plain.count, by: 4).filter { Int(plain[$0]) - Int(labelled[$0]) > 100 }.count
        #expect(darkened > 2000)
    }

    @Test func highlightsOutlineTheGroup() throws {
        let map = Fixture.map
        var frame = MapFrame(viewport: Viewport(bounds: map.projection.bounds, size: Vec2(1200, 640)),
                             contentsScale: 1, date: Fixture.date, style: .light)
        let plain = Self.pixels(try Self.renderer.image(frame, map: Self.map, width: 1200, height: 640))
        frame.highlights = [.init(group: map.labels[0].group, width: 2)]
        let outlined = Self.pixels(try Self.renderer.image(frame, map: Self.map, width: 1200, height: 640))
        let changed = stride(from: 0, to: plain.count, by: 4).filter { plain[$0] != outlined[$0] }.count
        #expect(changed > 200)
    }

    @Test func labelTextIsRasterised() throws {
        let entry = try #require(LabelTextures.rasterize(.init(text: "12:34", bold: true, step: LabelTextures.step(forPixels: 20)),
                                                         device: Self.renderer.device))
        #expect(entry.texture.width > 30 && entry.texture.height > 15)
        #expect(abs(entry.size - 20) < 0.5)
        #expect(entry.box.width > 25)
    }
}
