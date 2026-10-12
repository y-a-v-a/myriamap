import Foundation
import MyriaGeometry
import ZoneAtlas

/// Geographic layers intersected with every face of the mesh, stored in the
/// faces' local coordinates. Independent of the cuts, so one overlay serves
/// every unfolding of the same mesh.
public struct FaceOverlay: Sendable {
    /// The part of one timezone region inside one face.
    public struct ZoneFill: Sendable {
        public let region: Int
        /// Outer rings counter-clockwise, holes clockwise.
        public let rings: [[Vec2]]
        public let area: Double
    }

    public let zoneFills: [[ZoneFill]]
    /// Land rings per face (outer counter-clockwise, holes clockwise).
    public let landFills: [[[Vec2]]]
    public let borderLines: [[[Vec2]]]
    public let coastLines: [[[Vec2]]]

    public init(mesh: MyriahedralMesh, atlas: ZoneAtlas, land: LandMask?) {
        let faces = parallelMap(mesh.faceCount) { f in
            FaceOverlay.overlay(face: f, mesh: mesh, atlas: atlas, land: land)
        }
        zoneFills = faces.map(\.zones)
        landFills = faces.map(\.land)
        borderLines = faces.map(\.borders)
        coastLines = faces.map(\.coasts)
    }

    /// Region covering most of each face, or -1.
    public func dominantRegion(of face: Int) -> Int {
        zoneFills[face].max { $0.area < $1.area }?.region ?? -1
    }

    struct Face: Sendable {
        var zones: [ZoneFill]
        var land: [[Vec2]]
        var borders: [[Vec2]]
        var coasts: [[Vec2]]
    }

    static func overlay(face f: Int, mesh: MyriahedralMesh, atlas: ZoneAtlas, land: LandMask?) -> Face {
        let frame = mesh.frames[f]
        let clip = FaceClipper(frame: frame, vertices: mesh.polyhedron.faceVertices(f))
        let tiles = atlas.polygons.grid.tiles(aroundCap: GeoPoint(clip.center), radius: clip.radiusDegrees * 1.02 + 1e-6)

        var byRegion: [Int: (rings: [[Vec2]], area: Double)] = [:]
        for chunk in atlas.polygons.chunks(inTiles: tiles) {
            for ring in chunk.sphereRings {
                let piece = clip.clipPolygon(ring)
                guard piece.count >= 3 else { continue }
                let a = Planar.signedArea(piece)
                guard abs(a) > clip.area * 1e-12 else { continue }
                byRegion[chunk.feature, default: ([], 0)].rings.append(piece)
                byRegion[chunk.feature, default: ([], 0)].area += a
            }
        }
        var zones: [ZoneFill] = byRegion.map { region, value in
            // A region covering the whole face collapses to the face itself.
            if value.area >= clip.area * (1 - 1e-9) {
                return ZoneFill(region: region, rings: [frame.localVertices], area: clip.area)
            }
            return ZoneFill(region: region, rings: value.rings, area: value.area)
        }
        zones.removeAll { $0.area <= clip.area * 1e-9 }
        zones.sort { $0.area > $1.area }
        if zones.isEmpty, let r = atlas.polygons.feature(at: GeoPoint(clip.center)) {
            zones = [ZoneFill(region: r, rings: [frame.localVertices], area: clip.area)]
        }

        var landRings: [[Vec2]] = []
        var coasts: [[Vec2]] = []
        if let land {
            var landArea = 0.0
            for chunk in land.polygons.chunks(inTiles: tiles) {
                for ring in chunk.sphereRings {
                    let piece = clip.clipPolygon(ring)
                    let a = Planar.signedArea(piece)
                    guard piece.count >= 3, abs(a) > clip.area * 1e-12 else { continue }
                    landRings.append(piece)
                    landArea += a
                }
            }
            if landArea >= clip.area * (1 - 1e-9) { landRings = [frame.localVertices] }
            if landArea <= clip.area * 1e-9 { landRings = [] }
            coasts = clip.clipLines(land.coastlines, tiles: tiles)
        }
        let borders = clip.clipLines(atlas.borders, tiles: tiles)
        return Face(zones: zones, land: landRings, borders: borders, coasts: coasts)
    }
}

/// Clips spherical geometry to one face, returning local coordinates.
struct FaceClipper {
    let frame: FaceFrame
    let center: Vec3
    let radiusDegrees: Double
    let area: Double
    /// Pre-clip cap around the face normal; keeps gnomonic projection finite.
    let capCosine: Double

    init(frame: FaceFrame, vertices: [Vec3]) {
        self.frame = frame
        center = frame.normal
        let radius = vertices.map { frame.normal.angle(to: $0) }.max() ?? 0
        radiusDegrees = radius * 180 / .pi
        area = frame.area
        capCosine = cos(min(max(radius * 3, 3 * .pi / 180), 75 * .pi / 180))
    }

    func clipPolygon(_ ring: [Vec3]) -> [Vec2] {
        let capped = SphericalClip.clipRing(ring, axis: frame.normal, minimumCosine: capCosine)
        guard capped.count >= 3 else { return [] }
        let local = capped.compactMap { frame.gnomonic($0, minimumCosine: 0) }
        guard local.count == capped.count else { return [] }
        return Planar.clip(local, toConvex: frame.localVertices)
    }

    /// Clips the segments of a layer near this face, chaining consecutive
    /// pieces into polylines.
    func clipLines(_ layer: SegmentLayer, tiles: [Int]) -> [[Vec2]] {
        var lines: [[Vec2]] = []
        var current: [Vec2] = []
        var lastIndex = -2
        for i in layer.segmentIndices(inTiles: tiles) {
            let s = layer.segments[i]
            var a = s.a, b = s.b
            let da = frame.normal.dot(a) - capCosine, db = frame.normal.dot(b) - capCosine
            if da < 0 && db < 0 { continue }
            if da < 0 { a = (a + (b - a) * (da / (da - db))).normalized }
            if db < 0 { b = (a + (b - a) * (da / (da - db))).normalized }
            guard let la = frame.gnomonic(a, minimumCosine: 0), let lb = frame.gnomonic(b, minimumCosine: 0),
                  let (p, q) = Planar.clipSegment(la, lb, toConvex: frame.localVertices),
                  (q - p).lengthSquared > 1e-24
            else { continue }
            if i == lastIndex + 1, let end = current.last, (end - p).lengthSquared < 1e-20 {
                current.append(q)
            } else {
                if current.count >= 2 { lines.append(current) }
                current = [p, q]
            }
            lastIndex = i
        }
        if current.count >= 2 { lines.append(current) }
        return lines
    }
}
