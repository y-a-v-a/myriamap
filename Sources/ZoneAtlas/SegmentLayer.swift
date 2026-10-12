import Foundation
import MyriaGeometry

/// Great-circle segments (coastlines, zone borders) bucketed by tile.
public struct SegmentLayer: Sendable {
    public struct Segment: Sendable {
        public let a: Vec3
        public let b: Vec3
    }

    public let grid: TileGrid
    /// Segments in ring order, so consecutive indices usually chain.
    public let segments: [Segment]
    /// Segment indices per tile, ascending.
    public let tiles: [[Int32]]

    /// - Parameter polylines: open polylines in (longitude, latitude).
    public init(polylines: [[Vec2]], tileSize: Double = 5) {
        let grid = TileGrid(size: tileSize)
        var segments: [Segment] = []
        var tiles = Array(repeating: [Int32](), count: grid.count)
        for line in polylines where line.count >= 2 {
            for i in 0..<(line.count - 1) {
                let p = line[i], q = line[i + 1]
                let index = Int32(segments.count)
                segments.append(Segment(a: GeoPoint(latitude: p.y, longitude: p.x).unitVector,
                                        b: GeoPoint(latitude: q.y, longitude: q.x).unitVector))
                let box = Rect2(minX: min(p.x, q.x), minY: min(p.y, q.y), maxX: max(p.x, q.x), maxY: max(p.y, q.y))
                for t in grid.tiles(overlapping: box) { tiles[t].append(index) }
            }
        }
        self.grid = grid
        self.segments = segments
        self.tiles = tiles
    }

    /// Indices of the segments in the given tiles, ascending and unique.
    public func segmentIndices(inTiles tileIDs: [Int]) -> [Int] {
        var set = Set<Int32>()
        for t in tileIDs { set.formUnion(tiles[t]) }
        return set.map(Int.init).sorted()
    }

    /// Splits closed rings into polylines, dropping edges for which `keep` is
    /// false, and densifies the result.
    static func polylines(fromRings rings: [[Vec2]], keep: (Vec2, Vec2) -> Bool) -> [[Vec2]] {
        var out: [[Vec2]] = []
        for ring in rings where ring.count >= 2 {
            var current: [Vec2] = []
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                if keep(a, b) {
                    if current.isEmpty { current.append(a) }
                    current.append(b)
                } else if !current.isEmpty {
                    out.append(current)
                    current = []
                }
            }
            if !current.isEmpty { out.append(current) }
        }
        return out.map { line in
            var dense: [Vec2] = []
            for i in 0..<(line.count - 1) {
                let seg = GeoPolygon.densify([line[i], line[i + 1]], maxStep: PolygonLayer.maxEdgeDegrees)
                // densify treats the pair as a closed ring; keep the forward half.
                dense.append(contentsOf: seg.prefix { $0 != line[i + 1] })
            }
            dense.append(line[line.count - 1])
            return dense
        }
    }

    /// Edges that are artefacts of how polygons were stored: splits along
    /// the antimeridian and degenerate edges at the poles.
    static func isArtificial(_ a: Vec2, _ b: Vec2) -> Bool {
        (abs(a.x) == 180 && abs(b.x) == 180) || (abs(a.y) >= 89.9999 && abs(b.y) >= 89.9999)
    }
}
