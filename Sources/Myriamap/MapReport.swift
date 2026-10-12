import Foundation
import MyriaGeometry

/// Quality measures of an unfolded map.
public struct MapReport: Sendable {
    /// Faces whose map polygon overlaps another face's.
    public let overlappingFaces: [Int]
    public var overlappingFaceCount: Int { overlappingFaces.count }
    /// Summed pairwise overlap area as a fraction of the total face area.
    public let overlapFraction: Double

    public init(map: MyriaMap) {
        let polygons = map.projection.mapPolygons
        let bounds = map.projection.bounds
        let n = polygons.count
        let side = max(1, Int(Double(n).squareRoot()))
        let cell = max(bounds.width, bounds.height) / Double(side)
        var grid: [Int64: [Int]] = [:]
        func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }
        let boxes = polygons.map { Rect2(bounding: $0) }
        for (f, box) in boxes.enumerated() {
            for x in Int(((box.minX - bounds.minX) / cell).rounded(.down))...Int(((box.maxX - bounds.minX) / cell).rounded(.down)) {
                for y in Int(((box.minY - bounds.minY) / cell).rounded(.down))...Int(((box.maxY - bounds.minY) / cell).rounded(.down)) {
                    grid[key(x, y), default: []].append(f)
                }
            }
        }
        let areas = polygons.map(Planar.signedArea)
        var overlapping = Set<Int>()
        var seenPairs = Set<Int64>()
        var overlapArea = 0.0
        for bucket in grid.values where bucket.count > 1 {
            for i in 0..<bucket.count {
                for j in (i + 1)..<bucket.count {
                    let a = bucket[i], b = bucket[j]
                    guard boxes[a].insetBy(1e-12).intersects(boxes[b].insetBy(1e-12)) else { continue }
                    guard seenPairs.insert(Int64(min(a, b)) << 32 | Int64(max(a, b))).inserted else { continue }
                    let shared = Planar.signedArea(Planar.clip(polygons[a], toConvex: polygons[b]))
                    if shared > 1e-6 * min(areas[a], areas[b]) {
                        overlapping.insert(a)
                        overlapping.insert(b)
                        overlapArea += shared
                    }
                }
            }
        }
        overlappingFaces = overlapping.sorted()
        overlapFraction = overlapArea / max(areas.reduce(0, +), 1e-300)
    }
}
