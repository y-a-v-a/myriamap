import Foundation
import MyriaGeometry

public enum ZoneAtlasError: Error, CustomStringConvertible {
    case missingResource(String)

    public var description: String {
        switch self {
        case .missingResource(let name): "bundled resource \(name) not found"
        }
    }
}

/// Timezone regions with their boundary polygons, covering the whole globe
/// including the oceans.
public struct ZoneAtlas: Sendable {
    public let regions: [TimeZoneRegion]
    public let polygons: PolygonLayer
    /// Borders between different regions, each drawn once.
    public let borders: SegmentLayer

    public init(features: [GeoFeature], tileSize: Double = 5) {
        regions = features.enumerated().map { i, f in
            TimeZoneRegion(id: i, identifier: f.properties["tzid"] ?? f.properties["name"] ?? "Etc/Unknown")
        }
        polygons = PolygonLayer(features: features.map(\.polygons), tileSize: tileSize)
        borders = SegmentLayer(polylines: Self.borderPolylines(features), tileSize: tileSize)
    }

    public init(contentsOf url: URL) throws {
        self.init(features: try GeoJSON.features(from: Data(contentsOf: url)))
    }

    /// The atlas bundled with the package (timezone-boundary-builder data).
    public static func bundled() throws -> ZoneAtlas {
        try ZoneAtlas(contentsOf: BundledData.url(named: "timezones", extension: "geojson"))
    }

    public func region(at p: GeoPoint) -> TimeZoneRegion? {
        polygons.feature(at: p).map { regions[$0] }
    }

    public func region(named identifier: String) -> TimeZoneRegion? {
        regions.first { $0.identifier == identifier }
    }

    /// Border polylines: ring edges whose twin edge belongs to another region.
    /// Twins within one region (antimeridian splits) and pole-degenerate edges
    /// are dropped.
    static func borderPolylines(_ features: [GeoFeature]) -> [[Vec2]] {
        struct Key: Hashable {
            let a: Int64, b: Int64, c: Int64, d: Int64
            init(_ p: Vec2, _ q: Vec2) {
                func quantize(_ v: Vec2) -> (Int64, Int64) {
                    if abs(v.y) >= 89.99999 { return (Int64((v.y * 1e6).rounded()), 0) }
                    let lon = v.x >= 180 ? v.x - 360 : v.x
                    return (Int64((v.y * 1e6).rounded()), Int64((lon * 1e6).rounded()))
                }
                let (p0, p1) = quantize(p), (q0, q1) = quantize(q)
                if (p0, p1) <= (q0, q1) { (a, b, c, d) = (p0, p1, q0, q1) } else { (a, b, c, d) = (q0, q1, p0, p1) }
            }
        }
        var owners: [Key: [Int]] = [:]
        let rings: [(Int, [Vec2])] = features.enumerated().flatMap { i, f in
            f.polygons.flatMap { $0.rings.map { (i, GeoPolygon.planar($0)) } }
        }
        for (zone, ring) in rings {
            for j in ring.indices {
                owners[Key(ring[j], ring[(j + 1) % ring.count]), default: []].append(zone)
            }
        }
        var emitted = Set<Key>()
        var result: [[Vec2]] = []
        for (zone, ring) in rings {
            result += SegmentLayer.polylines(fromRings: [ring]) { a, b in
                let key = Key(a, b)
                let zones = owners[key] ?? []
                let shared = zones.contains { $0 != zone }
                if !shared {
                    // Twin in the same region, or degenerate at a pole.
                    if zones.count > 1 || SegmentLayer.isArtificial(a, b) { return false }
                }
                return emitted.insert(key).inserted
            }
        }
        return result
    }
}

/// Land polygons and their coastlines.
public struct LandMask: Sendable {
    public let polygons: PolygonLayer
    public let coastlines: SegmentLayer

    public init(features: [GeoFeature], tileSize: Double = 5) {
        let all = features.flatMap(\.polygons)
        polygons = PolygonLayer(features: [all], tileSize: tileSize)
        let rings = all.flatMap { $0.rings.map(GeoPolygon.planar) }
        coastlines = SegmentLayer(
            polylines: SegmentLayer.polylines(fromRings: rings) { !SegmentLayer.isArtificial($0, $1) },
            tileSize: tileSize)
    }

    public init(contentsOf url: URL) throws {
        self.init(features: try GeoJSON.features(from: Data(contentsOf: url)))
    }

    /// Natural Earth 1:50m land, bundled with the package.
    public static func bundled() throws -> LandMask {
        try LandMask(contentsOf: BundledData.url(named: "land", extension: "geojson"))
    }

    public func isLand(_ p: GeoPoint) -> Bool { polygons.feature(at: p) != nil }
}

enum BundledData {
    /// Looks in the main bundle first (assembled .app) and then in the
    /// SwiftPM resource bundle.
    static func url(named name: String, extension ext: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) { return url }
        throw ZoneAtlasError.missingResource("\(name).\(ext)")
    }
}
