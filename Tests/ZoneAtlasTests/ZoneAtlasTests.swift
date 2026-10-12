import Foundation
import Testing
import MyriaGeometry
@testable import ZoneAtlas

@Suite("GeoJSON and polygon layers")
struct PolygonLayerTests {
    static let sample = """
    {"type":"FeatureCollection","features":[
      {"type":"Feature","properties":{"tzid":"Test/Square","rank":3},
       "geometry":{"type":"Polygon","coordinates":[
         [[-10,-10],[10,-10],[10,10],[-10,10],[-10,-10]],
         [[-2,-2],[-2,2],[2,2],[2,-2],[-2,-2]]]}},
      {"type":"Feature","properties":{"tzid":"Test/Split"},
       "geometry":{"type":"MultiPolygon","coordinates":[
         [[[170,0],[180,0],[180,10],[170,10],[170,0]]],
         [[[-180,0],[-170,0],[-170,10],[-180,10],[-180,0]]]]}}
    ]}
    """

    @Test func parsesPolygonsHolesAndProperties() throws {
        let features = try GeoJSON.features(from: Data(Self.sample.utf8))
        #expect(features.count == 2)
        #expect(features[0].properties["tzid"] == "Test/Square")
        #expect(features[0].properties["rank"] == "3")
        #expect(features[0].polygons.count == 1)
        #expect(features[0].polygons[0].rings.count == 2)
        // Closing points are dropped.
        #expect(features[0].polygons[0].outer.count == 4)
        #expect(features[1].polygons.count == 2)
    }

    @Test func expandsPoleVerticesAlongThePoleLine() {
        // A lune whose (-180, 90) corner was simplified away.
        let ring = [GeoPoint(latitude: 67, longitude: -172.5), GeoPoint(latitude: 90, longitude: -172.5),
                    GeoPoint(latitude: 71, longitude: -180)]
        let fixed = GeoPolygon.expandingPoles(ring)
        #expect(fixed.map(\.longitude) == [-172.5, -172.5, -180, -180])
        #expect(fixed.map(\.latitude) == [67, 90, 90, 71])
        // Already-explicit pole edges are unchanged.
        let explicit = [GeoPoint(latitude: 60, longitude: 0), GeoPoint(latitude: 90, longitude: 0),
                        GeoPoint(latitude: 90, longitude: 10), GeoPoint(latitude: 60, longitude: 10)]
        #expect(GeoPolygon.expandingPoles(explicit) == explicit)
    }

    @Test func rejectsNonCollections() {
        #expect(throws: GeoJSONError.self) {
            try GeoJSON.features(from: Data(#"{"type":"Feature"}"#.utf8))
        }
    }

    @Test func lookupRespectsHolesAndTiles() throws {
        let atlas = ZoneAtlas(features: try GeoJSON.features(from: Data(Self.sample.utf8)))
        #expect(atlas.region(at: GeoPoint(latitude: 5, longitude: 5))?.identifier == "Test/Square")
        #expect(atlas.region(at: GeoPoint(latitude: -9, longitude: 9))?.identifier == "Test/Square")
        #expect(atlas.region(at: GeoPoint(latitude: 0, longitude: 0)) == nil)  // in the hole
        #expect(atlas.region(at: GeoPoint(latitude: 20, longitude: 0)) == nil)
        #expect(atlas.region(at: GeoPoint(latitude: 5, longitude: 179.5))?.identifier == "Test/Split")
        #expect(atlas.region(at: GeoPoint(latitude: 5, longitude: -179.5))?.identifier == "Test/Split")
        #expect(atlas.region(at: GeoPoint(latitude: 5, longitude: 180))?.identifier == "Test/Split")
    }

    @Test func tilingPreservesArea() throws {
        let features = try GeoJSON.features(from: Data(Self.sample.utf8))
        let layer = PolygonLayer(features: features.map(\.polygons), tileSize: 3)
        var area = [0.0, 0.0]
        for chunk in layer.tiles.joined() {
            area[chunk.feature] += chunk.rings.reduce(0) { $0 + Planar.signedArea($1) }
        }
        #expect(abs(area[0] - (400 - 16)) < 1e-9)
        #expect(abs(area[1] - 200) < 1e-9)
    }

    @Test func bordersSkipAntimeridianSplitsAndDuplicates() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"tzid":"A"},"geometry":{"type":"MultiPolygon","coordinates":[
            [[[170,0],[180,0],[180,10],[170,10],[170,0]]],
            [[[-180,0],[-175,0],[-175,10],[-180,10],[-180,0]]]]}},
          {"type":"Feature","properties":{"tzid":"B"},"geometry":{"type":"Polygon","coordinates":[
            [[-175,0],[-170,0],[-170,10],[-175,10],[-175,0]]]}}
        ]}
        """
        let atlas = ZoneAtlas(features: try GeoJSON.features(from: Data(json.utf8)))
        let lines = ZoneAtlas.borderPolylines(try GeoJSON.features(from: Data(json.utf8)))
        // No border along the antimeridian, where A meets itself.
        for line in lines {
            #expect(!line.allSatisfy { abs($0.x) == 180 })
        }
        // The shared A/B edge at -175 appears exactly once.
        // The shared A/B edge at -175 (densified into 10 steps) appears once.
        let sharedSteps = lines.flatMap { line in
            zip(line, line.dropFirst()).filter { $0.0.x == -175 && $0.1.x == -175 }
        }
        #expect(sharedSteps.count == 10)
        #expect(atlas.borders.segments.count > 0)
    }
}

@Suite("Bundled timezone data")
struct BundledAtlasTests {
    static let atlas = try! ZoneAtlas.bundled()

    @Test(arguments: [
        (52.37, 4.89, "Europe/Paris"),       // Amsterdam
        (51.51, -0.13, "Europe/London"),
        (40.71, -74.01, "America/New_York"),
        (34.05, -118.24, "America/Los_Angeles"),
        (35.68, 139.69, "Asia/Tokyo"),
        (19.08, 72.88, "Asia/Kolkata"),      // Mumbai
        (27.72, 85.32, "Asia/Kathmandu"),
        (-33.87, 151.21, "Australia/Sydney"),
        (21.31, -157.86, "Pacific/Honolulu"),
        (55.76, 37.62, "Europe/Moscow"),
    ])
    func knownCities(latitude: Double, longitude: Double, expected: String) {
        let region = Self.atlas.region(at: GeoPoint(latitude: latitude, longitude: longitude))
        #expect(region?.identifier == expected)
    }

    @Test func coversTheWholeGlobe() {
        var missing = 0, total = 0
        for lat in stride(from: -89.75, through: 89.75, by: 1.5) {
            for lon in stride(from: -179.75, through: 179.75, by: 1.5) {
                total += 1
                if Self.atlas.region(at: GeoPoint(latitude: lat, longitude: lon)) == nil { missing += 1 }
            }
        }
        #expect(missing == 0, "\(missing) of \(total) samples fall outside every zone")
    }

    @Test func openOceanFollowsNauticalZones() {
        // Far from land, the offset is the nearest multiple of 15° in hours.
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for hours in [-9, -6, -3, 0, 3, 6, 9] {
            let p = GeoPoint(latitude: -55, longitude: Double(hours) * 15)
            let region = Self.atlas.region(at: p)
            #expect(region?.utcOffset(at: date) == hours * 3600, "at \(p)")
        }
    }

    @Test func bordersExist() {
        #expect(Self.atlas.regions.count > 50)
        #expect(Self.atlas.borders.segments.count > 1000)
    }
}

@Suite("Clocks and the sun")
struct ClockTests {
    let date = ISO8601DateFormatter().date(from: "2026-01-15T12:34:56Z")!

    @Test func offsetsAndClockFaces() {
        let kolkata = TimeZoneRegion(id: 0, identifier: "Asia/Kolkata")
        #expect(kolkata.utcOffset(at: date) == 19_800)
        #expect(kolkata.offsetLabel(at: date) == "UTC+05:30")
        #expect(kolkata.clockTime(at: date) == "18:04")
        #expect(kolkata.clockTime(at: date, seconds: true) == "18:04:56")
        #expect(kolkata.placeName == "Kolkata")

        let ny = TimeZoneRegion(id: 1, identifier: "America/New_York")
        #expect(ny.offsetLabel(at: date) == "UTC−05:00")
        #expect(!ny.isDaylightSavingTime(at: date))
        #expect(ny.placeName == "New York")

        let dateLine = TimeZoneRegion(id: 2, identifier: "Etc/GMT+12")
        #expect(dateLine.utcOffset(at: date) == -12 * 3600)
        #expect(dateLine.placeName == "Open ocean")
        #expect(TimeZoneRegion.offsetLabel(seconds: 0) == "UTC±00:00")
    }

    @Test func dayOffsetAcrossTheDateLine() {
        let late = ISO8601DateFormatter().date(from: "2026-01-15T20:00:00Z")!
        #expect(TimeZoneRegion(id: 0, identifier: "Pacific/Kiritimati").dayOffset(at: late) == 1)
        #expect(TimeZoneRegion(id: 0, identifier: "Etc/GMT+12").dayOffset(at: late) == 0)
        let early = ISO8601DateFormatter().date(from: "2026-01-15T04:00:00Z")!
        #expect(TimeZoneRegion(id: 0, identifier: "Pacific/Honolulu").dayOffset(at: early) == -1)
    }

    @Test func subsolarPointAtSolsticesAndEquinox() {
        let iso = ISO8601DateFormatter()
        let june = SolarPosition.subsolarPoint(at: iso.date(from: "2026-06-21T12:00:00Z")!)
        #expect(abs(june.latitude - 23.44) < 0.1)
        #expect(abs(june.longitude) < 1.5)

        let december = SolarPosition.subsolarPoint(at: iso.date(from: "2026-12-21T12:00:00Z")!)
        #expect(abs(december.latitude + 23.44) < 0.1)
        // The equation of time is about +2 minutes: noon comes early, so at
        // 12:00 UTC the sun has already moved ~0.5° west of Greenwich.
        #expect(abs(december.longitude + 0.5) < 0.3)

        let equinox = SolarPosition.subsolarPoint(at: iso.date(from: "2026-03-20T14:46:00Z")!)
        #expect(abs(equinox.latitude) < 0.1)
        // 2h46m after noon is 41.5°W, less 7.5 minutes (≈1.9°) of equation of time.
        #expect(abs(equinox.longitude + 39.6) < 0.3)
    }

    @Test func elevationIsPositiveUnderTheSun() {
        let p = SolarPosition.subsolarPoint(at: date)
        #expect(SolarPosition.elevation(at: p, date: date) > 89.9)
        let antipode = GeoPoint(latitude: -p.latitude, longitude: Spherical.normalizeLongitude(p.longitude + 180))
        #expect(SolarPosition.elevation(at: antipode, date: date) < -89.9)
    }
}

@Suite("Bundled land data")
struct LandMaskTests {
    static let land = try! LandMask.bundled()

    @Test(arguments: [
        (48.85, 2.35, true),     // Paris
        (-80.0, 0.0, true),      // Antarctica
        (-89.9, 120.0, true),    // near the South Pole
        (75.0, -40.0, true),     // Greenland
        (0.0, -30.0, false),     // Atlantic
        (-40.0, -140.0, false),  // South Pacific
        (89.0, 0.0, false),      // Arctic Ocean
    ])
    func landOrWater(latitude: Double, longitude: Double, expected: Bool) {
        #expect(Self.land.isLand(GeoPoint(latitude: latitude, longitude: longitude)) == expected)
    }

    @Test func coastlinesSkipArtificialEdges() {
        #expect(Self.land.coastlines.segments.count > 10_000)
        for s in Self.land.coastlines.segments {
            let a = GeoPoint(s.a), b = GeoPoint(s.b)
            #expect(!(abs(a.latitude) > 89.999 && abs(b.latitude) > 89.999))
        }
    }
}
