import Foundation
import MyriaGeometry

/// A polygon in longitude/latitude: the outer ring followed by any holes.
/// Rings are open (the closing point is not repeated).
public struct GeoPolygon: Sendable {
    public var rings: [[GeoPoint]]

    public init(rings: [[GeoPoint]]) {
        self.rings = rings
    }

    public var outer: [GeoPoint] { rings.first ?? [] }
}

/// A GeoJSON feature reduced to its polygons and string properties.
public struct GeoFeature: Sendable {
    public var properties: [String: String]
    public var polygons: [GeoPolygon]

    public init(properties: [String: String], polygons: [GeoPolygon]) {
        self.properties = properties
        self.polygons = polygons
    }
}

public enum GeoJSONError: Error, CustomStringConvertible {
    case notAFeatureCollection
    case malformedGeometry(String)

    public var description: String {
        switch self {
        case .notAFeatureCollection: "expected a GeoJSON FeatureCollection"
        case .malformedGeometry(let detail): "malformed geometry: \(detail)"
        }
    }
}

/// Minimal GeoJSON reader for polygon feature collections.
public enum GeoJSON {
    public static func features(from data: Data) throws -> [GeoFeature] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "FeatureCollection",
              let features = root["features"] as? [[String: Any]]
        else { throw GeoJSONError.notAFeatureCollection }

        return try features.map { feature in
            var properties: [String: String] = [:]
            for (key, value) in feature["properties"] as? [String: Any] ?? [:] {
                switch value {
                case let s as String: properties[key] = s
                case let n as NSNumber: properties[key] = n.stringValue
                default: break
                }
            }
            guard let geometry = feature["geometry"] as? [String: Any] else {
                return GeoFeature(properties: properties, polygons: [])
            }
            return GeoFeature(properties: properties, polygons: try polygons(geometry))
        }
    }

    static func polygons(_ geometry: [String: Any]) throws -> [GeoPolygon] {
        let type = geometry["type"] as? String
        switch type {
        case "Polygon":
            guard let coords = geometry["coordinates"] as? [Any] else {
                throw GeoJSONError.malformedGeometry("Polygon without coordinates")
            }
            return [try polygon(coords)]
        case "MultiPolygon":
            guard let coords = geometry["coordinates"] as? [Any] else {
                throw GeoJSONError.malformedGeometry("MultiPolygon without coordinates")
            }
            return try coords.map { item in
                guard let p = item as? [Any] else { throw GeoJSONError.malformedGeometry("MultiPolygon member") }
                return try polygon(p)
            }
        case "GeometryCollection":
            let members = geometry["geometries"] as? [[String: Any]] ?? []
            return try members.flatMap(polygons)
        default:
            return []
        }
    }

    static func polygon(_ coords: [Any]) throws -> GeoPolygon {
        let rings: [[GeoPoint]] = try coords.map { ringValue in
            guard let ring = ringValue as? [[Any]] else { throw GeoJSONError.malformedGeometry("ring") }
            var points: [GeoPoint] = []
            points.reserveCapacity(ring.count)
            for position in ring {
                guard position.count >= 2,
                      let lon = (position[0] as? NSNumber)?.doubleValue,
                      let lat = (position[1] as? NSNumber)?.doubleValue
                else { throw GeoJSONError.malformedGeometry("position") }
                points.append(GeoPoint(latitude: lat, longitude: lon))
            }
            if points.count > 1, points.first == points.last { points.removeLast() }
            return GeoPolygon.expandingPoles(points)
        }
        return GeoPolygon(rings: rings.filter { $0.count >= 3 })
    }
}

extension GeoPolygon {
    /// On the sphere a pole is a single point, so spherical simplifiers may
    /// drop the second corner of an edge running along latitude ±90°. In the
    /// planar longitude/latitude view that edge matters: each pole vertex is
    /// replaced by points at its neighbours' longitudes so the ring runs
    /// along the pole line instead of cutting diagonally across.
    static func expandingPoles(_ ring: [GeoPoint]) -> [GeoPoint] {
        func isPole(_ p: GeoPoint) -> Bool { abs(p.latitude) >= 90 - 1e-9 }
        guard ring.count >= 3, ring.contains(where: isPole) else { return ring }
        var out: [GeoPoint] = []
        for i in ring.indices {
            let p = ring[i]
            guard isPole(p) else {
                out.append(p)
                continue
            }
            let prev = ring[(i + ring.count - 1) % ring.count], next = ring[(i + 1) % ring.count]
            if !isPole(prev) { out.append(GeoPoint(latitude: p.latitude, longitude: prev.longitude)) }
            if !isPole(next) { out.append(GeoPoint(latitude: p.latitude, longitude: next.longitude)) }
        }
        return out
    }

    /// Planar (longitude, latitude) coordinates of a ring.
    static func planar(_ ring: [GeoPoint]) -> [Vec2] { ring.map { Vec2($0.longitude, $0.latitude) } }

    /// Inserts points so no edge is longer than `maxStep` degrees in
    /// longitude/latitude. Short edges then follow great circles closely,
    /// and long meridian edges (pole to pole) stay well defined on the sphere.
    static func densify(_ ring: [Vec2], maxStep: Double) -> [Vec2] {
        guard ring.count > 1 else { return ring }
        var out: [Vec2] = []
        out.reserveCapacity(ring.count)
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            out.append(a)
            let steps = Int((max(abs(b.x - a.x), abs(b.y - a.y)) / maxStep).rounded(.up))
            if steps > 1 {
                for k in 1..<steps { out.append(Vec2.lerp(a, b, Double(k) / Double(steps))) }
            }
        }
        return out
    }
}
