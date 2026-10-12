import Foundation
import MyriaGeometry

/// The part of one feature's polygon inside one tile.
public struct PolygonChunk: Sendable {
    public let feature: Int
    /// Rings in (longitude, latitude); outer rings counter-clockwise, holes clockwise.
    public let rings: [[Vec2]]
    /// The same rings as unit vectors, edges read as great-circle arcs.
    public let sphereRings: [[Vec3]]
    public let bounds: Rect2

    /// Even-odd containment over all rings, so holes are respected.
    public func contains(_ p: Vec2) -> Bool {
        guard bounds.contains(p) else { return false }
        var inside = false
        for ring in rings where Planar.contains(ring, p) { inside.toggle() }
        return inside
    }
}

/// Polygon features cut into tile-sized chunks. Small chunks make point
/// lookup fast and let each mesh face clip only nearby geometry.
public struct PolygonLayer: Sendable {
    public let grid: TileGrid
    public let featureCount: Int
    /// Chunks per tile.
    public let tiles: [[PolygonChunk]]

    /// Longest edge, in degrees, kept after densifying.
    public static let maxEdgeDegrees = 1.0

    public init(features: [[GeoPolygon]], tileSize: Double = 5) {
        let grid = TileGrid(size: tileSize)
        var tiles = Array(repeating: [PolygonChunk](), count: grid.count)
        for (feature, polygons) in features.enumerated() {
            for polygon in polygons {
                // Orient rings consistently: outer CCW, holes CW (lon = x, lat = y).
                let rings: [[Vec2]] = polygon.rings.enumerated().map { i, ring in
                    let planar = GeoPolygon.densify(GeoPolygon.planar(ring), maxStep: Self.maxEdgeDegrees)
                    let ccw = Planar.signedArea(planar) > 0
                    return (i == 0) == ccw ? planar : planar.reversed()
                }
                guard let outer = rings.first else { continue }
                let bounds = Rect2(bounding: outer)
                for tile in grid.tiles(overlapping: bounds) {
                    let rect = grid.rect(tile)
                    let clipBox = [Vec2(rect.minX, rect.minY), Vec2(rect.maxX, rect.minY),
                                   Vec2(rect.maxX, rect.maxY), Vec2(rect.minX, rect.maxY)]
                    var clipped: [[Vec2]] = []
                    for (i, ring) in rings.enumerated() {
                        let r = Rect2(bounding: ring)
                        guard r.intersects(rect) else { continue }
                        let c = GeoPolygon.densify(Planar.clip(ring, toConvex: clipBox), maxStep: Self.maxEdgeDegrees)
                        guard abs(Planar.signedArea(c)) > 1e-12 else {
                            if i == 0 { break } else { continue }
                        }
                        clipped.append(c)
                    }
                    // A hole without its outer ring can't occur: holes lie inside the outer ring.
                    guard !clipped.isEmpty, Planar.signedArea(clipped[0]) > 0 else { continue }
                    tiles[tile].append(PolygonChunk(
                        feature: feature,
                        rings: clipped,
                        sphereRings: clipped.map { $0.map { GeoPoint(latitude: $0.y, longitude: $0.x).unitVector } },
                        bounds: Rect2(bounding: clipped[0])))
                }
            }
        }
        self.grid = grid
        featureCount = features.count
        self.tiles = tiles
    }

    /// The feature covering a location, if any.
    public func feature(at p: GeoPoint) -> Int? {
        let q = Vec2(Spherical.normalizeLongitude(p.longitude == 180 ? 179.9999999 : p.longitude), p.latitude)
        let tile = grid.tile(of: p)
        for chunk in tiles[tile] where chunk.contains(q) {
            return chunk.feature
        }
        // Points on a tile's edge are ambiguous for the even-odd test against
        // a chunk that fills the tile; retry a hair towards the tile centre.
        let center = grid.rect(tile).center
        let nudged = q + (center - q).normalized * 1e-7
        for chunk in tiles[tile] where chunk.contains(nudged) {
            return chunk.feature
        }
        return nil
    }

    /// Chunks in the given tiles.
    public func chunks(inTiles tileIDs: [Int]) -> [PolygonChunk] {
        tileIDs.flatMap { tiles[$0] }
    }
}
