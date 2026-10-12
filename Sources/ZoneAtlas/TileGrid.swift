import Foundation
import MyriaGeometry

/// Square longitude/latitude tiles used to bucket geometry spatially.
public struct TileGrid: Hashable, Sendable {
    public let size: Double
    public let cols: Int
    public let rows: Int

    public init(size: Double) {
        self.size = size
        cols = Int((360 / size).rounded(.up))
        rows = Int((180 / size).rounded(.up))
    }

    public var count: Int { cols * rows }

    public func col(ofLongitude lon: Double) -> Int {
        min(cols - 1, max(0, Int(((lon + 180) / size).rounded(.down))))
    }

    public func row(ofLatitude lat: Double) -> Int {
        min(rows - 1, max(0, Int(((lat + 90) / size).rounded(.down))))
    }

    public func tile(of p: GeoPoint) -> Int {
        row(ofLatitude: p.latitude) * cols + col(ofLongitude: Spherical.normalizeLongitude(p.longitude == 180 ? 179.999999 : p.longitude))
    }

    /// Rectangle of a tile as (longitude, latitude).
    public func rect(_ tile: Int) -> Rect2 {
        let r = tile / cols, c = tile % cols
        let minX = -180 + Double(c) * size, minY = -90 + Double(r) * size
        return Rect2(minX: minX, minY: minY, maxX: min(180, minX + size), maxY: min(90, minY + size))
    }

    /// Tiles overlapping a longitude/latitude rectangle (no wrap-around).
    public func tiles(overlapping r: Rect2) -> [Int] {
        guard !r.isEmpty else { return [] }
        let c0 = col(ofLongitude: r.minX), c1 = col(ofLongitude: r.maxX)
        let r0 = row(ofLatitude: r.minY), r1 = row(ofLatitude: r.maxY)
        var out: [Int] = []
        for row in r0...r1 {
            for c in c0...c1 { out.append(row * cols + c) }
        }
        return out
    }

    /// Tiles overlapping the spherical cap of `radius` degrees around `center`,
    /// handling the poles and the antimeridian.
    public func tiles(aroundCap center: GeoPoint, radius: Double) -> [Int] {
        let lat0 = center.latitude - radius, lat1 = center.latitude + radius
        let cosLat = cos(center.latitude * .pi / 180)
        let sinR = sin(min(radius, 90) * .pi / 180)
        if lat0 <= -90 || lat1 >= 90 || sinR >= cosLat {
            return tiles(overlapping: Rect2(minX: -180, minY: max(-90, lat0), maxX: 180, maxY: min(90, lat1)))
        }
        let dLon = asin(sinR / cosLat) * 180 / .pi
        let lon0 = center.longitude - dLon, lon1 = center.longitude + dLon
        var rects: [Rect2] = []
        if lon0 < -180 {
            rects.append(Rect2(minX: lon0 + 360, minY: lat0, maxX: 180, maxY: lat1))
            rects.append(Rect2(minX: -180, minY: lat0, maxX: lon1, maxY: lat1))
        } else if lon1 > 180 {
            rects.append(Rect2(minX: lon0, minY: lat0, maxX: 180, maxY: lat1))
            rects.append(Rect2(minX: -180, minY: lat0, maxX: lon1 - 360, maxY: lat1))
        } else {
            rects.append(Rect2(minX: lon0, minY: lat0, maxX: lon1, maxY: lat1))
        }
        var seen = Set<Int>()
        return rects.flatMap(tiles(overlapping:)).filter { seen.insert($0).inserted }
    }
}
