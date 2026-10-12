import ArgumentParser
import Foundation
import MyriaGeometry
import Myriamap
import ZoneAtlas

@main
struct MyriamapCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "myriamap",
        abstract: "A timezone map cut along timezone borders and unfolded as a myriahedral projection.",
        subcommands: [Render.self, Zone.self, Zones.self, Stats.self],
        defaultSubcommand: Render.self)
}

/// Options shared by commands that build a map.
struct MapOptions: ParsableArguments {
    @Option(help: "Mesh: graticule:<degrees> or geodesic:<frequency>.")
    var mesh: String = "graticule:1.875"

    @Option(help: "Where to cut: timezones or landmass.")
    var cuts: String = "timezones"

    @Option(help: "Timezone borders that become cuts: region (distinct clocks) or utcOffset (offsets at --date).")
    var grouping: String = "region"

    @Option(help: "Central longitude of the equatorial belt.")
    var center: Double = 10

    @Option(help: "Preference of cross-border hinges for low latitudes.")
    var equatorBias: Double = 2

    @Option(help: "ISO 8601 date for clocks, daylight and offsets (default: now).")
    var date: String?

    func resolvedDate() throws -> Date {
        guard let date else { return Date() }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: date) { return d }
        iso.formatOptions = [.withFullDate]
        if let d = iso.date(from: date) { return d }
        throw ValidationError("Cannot parse date '\(date)'; use e.g. 2026-10-12T12:00:00Z")
    }

    func configuration() throws -> MapConfiguration {
        guard let mesh = MeshKind(argument: mesh) else {
            throw ValidationError("Unknown mesh '\(mesh)'; use graticule:1.875 or geodesic:32")
        }
        guard let cuts = MapConfiguration.Cuts(rawValue: cuts) else {
            throw ValidationError("--cuts must be timezones or landmass")
        }
        guard let grouping = CutGrouping(rawValue: grouping) else {
            throw ValidationError("--grouping must be region or utcOffset")
        }
        return MapConfiguration(mesh: mesh, cuts: cuts, grouping: grouping, centerLongitude: center,
                                equatorBias: equatorBias, referenceDate: try resolvedDate())
    }
}

func timed<T>(_ label: String, verbose: Bool, _ work: () throws -> T) rethrows -> T {
    let start = Date()
    let result = try work()
    if verbose {
        FileHandle.standardError.write(Data(String(format: "%@: %.2fs\n", label, Date().timeIntervalSince(start)).utf8))
    }
    return result
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render the map to SVG or PNG.")

    @OptionGroup var map: MapOptions

    @Option(name: .shortAndLong, help: "Output file (.svg or .png).")
    var output: String = "myriamap.svg"

    @Option(help: "Output width in pixels.")
    var width: Int = 2400

    @Flag(help: "Use the dark palette.")
    var dark = false

    @Flag(help: "Omit the day/night shading.")
    var noNight = false

    @Flag(help: "Omit clock labels.")
    var noLabels = false

    @Flag(help: "Draw the cut edges.")
    var showCuts = false

    @Flag(help: "Draw the polyhedron's faces.")
    var showMesh = false

    @Flag(help: "Mark faces that overlap other faces in the unfolded map.")
    var showOverlaps = false

    @Flag(name: .shortAndLong, help: "Print timings.")
    var verbose = false

    func run() throws {
        let configuration = try map.configuration()
        let data = try timed("load data", verbose: verbose) { try GeoData.bundled() }
        let base = try timed("mesh + overlay", verbose: verbose) { try MeshOverlay(kind: configuration.mesh, data: data) }
        let built = timed("cut + unfold", verbose: verbose) {
            MyriaMap(base: base, data: data, configuration: configuration)
        }
        var options = SceneOptions(date: configuration.referenceDate, style: dark ? .dark : .light)
        options.showNight = !noNight
        options.showLabels = !noLabels
        options.showCuts = showCuts
        options.showMesh = showMesh
        if showOverlaps { options.markedFaces = MapReport(map: built).overlappingFaces }
        let scene = timed("scene", verbose: verbose) { built.scene(options) }
        let url = URL(fileURLWithPath: output)
        try timed("write", verbose: verbose) {
            if url.pathExtension.lowercased() == "png" {
                try BitmapRenderer.png(scene, width: width).write(to: url)
            } else {
                let title = "Myriamap — \(configuration.mesh.title)"
                try SVGRenderer.render(scene, width: Double(width), title: title).write(to: url, atomically: true, encoding: .utf8)
            }
        }
        print("Wrote \(url.path)")
    }
}

struct Zone: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the timezone region and local time at a location.")

    @Argument(help: "Latitude in degrees (north positive).")
    var latitude: Double

    @Argument(help: "Longitude in degrees (east positive).")
    var longitude: Double

    @Option(help: "ISO 8601 date (default: now).")
    var date: String?

    func run() throws {
        let atlas = try ZoneAtlas.bundled()
        let options = try MapOptions.parse(date.map { ["--date", $0] } ?? [])
        let when = try options.resolvedDate()
        let p = GeoPoint(latitude: latitude, longitude: longitude)
        guard let region = atlas.region(at: p) else {
            throw ValidationError("No timezone region found at \(p)")
        }
        print("\(p)")
        print("Region:   \(region.identifier) (\(region.placeName))")
        print("Time:     \(region.clockTime(at: when, seconds: true)) \(region.abbreviation(at: when))")
        print("Offset:   \(region.offsetLabel(at: when))\(region.isDaylightSavingTime(at: when) ? " (daylight saving)" : "")")
        let elevation = SolarPosition.elevation(at: p, date: when)
        print(String(format: "Sun:      %.1f° %@", elevation, elevation > 0 ? "above the horizon" : "below the horizon"))
    }
}

struct Zones: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List every region with its current time.")

    @Option(help: "ISO 8601 date (default: now).")
    var date: String?

    func run() throws {
        let atlas = try ZoneAtlas.bundled()
        let options = try MapOptions.parse(date.map { ["--date", $0] } ?? [])
        let when = try options.resolvedDate()
        let sorted = atlas.regions.sorted {
            ($0.utcOffset(at: when), $0.identifier) < ($1.utcOffset(at: when), $1.identifier)
        }
        for r in sorted {
            let day = r.dayOffset(at: when)
            let dayLabel = day == 0 ? "" : (day > 0 ? " (+\(day)d)" : " (\(day)d)")
            print("\(r.offsetLabel(at: when).padding(toLength: 11, withPad: " ", startingAt: 0)) "
                + "\(r.clockTime(at: when))\(dayLabel.padding(toLength: 6, withPad: " ", startingAt: 0)) \(r.identifier)")
        }
    }
}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Describe the mesh, its cuts and the unfolded pieces.")

    @OptionGroup var map: MapOptions

    func run() throws {
        let configuration = try map.configuration()
        let data = try GeoData.bundled()
        let start = Date()
        let built = try MyriaMap(data: data, configuration: configuration)
        let elapsed = Date().timeIntervalSince(start)
        let mesh = built.mesh, projection = built.projection
        let cutEdges = projection.cutEdges
        let borderCuts = cutEdges.filter { e in
            let edge = mesh.topology.edges[e]
            return built.faceGroups[edge.leftFace] != built.faceGroups[edge.rightFace]
        }
        let crossings = mesh.topology.edges.filter { built.faceGroups[$0.leftFace] != built.faceGroups[$0.rightFace] }
        let pieces = built.pieces()
        let report = MapReport(map: built)
        print("Mesh:            \(configuration.mesh.title)")
        print("Faces/vertices:  \(mesh.faceCount) / \(mesh.polyhedron.vertexCount)")
        print("Edges:           \(mesh.topology.edgeCount) (\(mesh.faceCount - 1) hinges, \(cutEdges.count) cuts)")
        print("Border edges:    \(crossings.count), of which cut: \(borderCuts.count) "
            + String(format: "(%.1f%%)", 100 * Double(borderCuts.count) / Double(max(crossings.count, 1))))
        print("Zone groups:     \(built.grouping.groups.count), pieces: \(pieces.count)")
        print("Map size:        " + String(format: "%.3f × %.3f", projection.bounds.width, projection.bounds.height))
        print("Overlaps:        \(report.overlappingFaceCount) faces, "
            + String(format: "%.3f%% of the map area", 100 * report.overlapFraction))
        print(String(format: "Build time:      %.2fs", elapsed))
    }
}
