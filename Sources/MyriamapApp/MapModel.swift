import AppKit
import MyriaGeometry
import Myriamap
import Observation
import SwiftUI
import ZoneAtlas

/// A scene path converted to a SwiftUI path in map coordinates.
struct LayerPath: Sendable {
    let role: ScenePath.Role
    let path: Path
    let fill: Color?
    let stroke: Color?
    let lineWidth: Double
    let group: Int?

    init(_ scenePath: ScenePath) {
        role = scenePath.role
        path = Path { p in
            for sub in scenePath.subpaths where sub.count >= 2 {
                p.addLines(sub.map { CGPoint(x: $0.x, y: $0.y) })
                if scenePath.closed { p.closeSubpath() }
            }
        }
        fill = scenePath.fill.map(Color.init)
        stroke = scenePath.stroke.map(Color.init)
        lineWidth = scenePath.lineWidth
        group = scenePath.group
    }
}

extension Color {
    init(_ c: RGBA) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

/// What the pointer is over.
struct HoverInfo: Equatable {
    let region: TimeZoneRegion
    let location: GeoPoint
    let group: Int
    let viewPoint: CGPoint
}

/// Display toggles that don't require re-cutting the map.
struct DisplayOptions: Hashable {
    var night = true
    var land = true
    var coastlines = true
    var borders = true
    var labels = true
    var cuts = false
    var mesh = false
}

@MainActor @Observable
final class MapModel {
    // Inputs.
    var meshKind: MeshKind = .graticule(step: 1.875) { didSet { if meshKind != oldValue { rebuild() } } }
    var cuts: MapConfiguration.Cuts = .timezones { didSet { if cuts != oldValue { rebuild() } } }
    var grouping: CutGrouping = .region { didSet { if grouping != oldValue { rebuild() } } }
    var centerLongitude: Double = 10
    var display = DisplayOptions() { didSet { if display != oldValue { refreshLayers() } } }
    var dark = false { didSet { if dark != oldValue { refreshLayers() } } }
    /// Offset from the real clock, for scrubbing through the day.
    var timeOffset: TimeInterval = 0 { didSet { refreshNight() } }
    var now = Date()

    // Outputs.
    private(set) var map: MyriaMap?
    private(set) var staticLayers: [LayerPath] = []
    private(set) var nightLayers: [LayerPath] = []
    private(set) var colorSlots: [Int] = []
    private(set) var isBuilding = false
    private(set) var status = "Loading timezone data…"
    var hover: HoverInfo?
    var selectedGroup: Int?

    private var data: GeoData?
    private var overlays: [MeshKind: MeshOverlay] = [:]
    private var buildTask: Task<Void, Never>?
    private var nightMinute = -1
    private var clock: Timer?

    var date: Date { now.addingTimeInterval(timeOffset) }
    var style: MapStyle { dark ? .dark : .light }

    func start() {
        guard data == nil, buildTask == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        buildTask = Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try GeoData.bundled() }.value
                data = loaded
                buildTask = nil
                rebuild()
            } catch {
                status = "Could not load data: \(error)"
            }
        }
    }

    private func tick() {
        now = Date()
        refreshNight()
    }

    /// Re-cuts and unfolds the map for the current settings, off the main thread.
    func rebuild() {
        guard let data else { return }
        buildTask?.cancel()
        isBuilding = true
        status = "Unfolding \(meshKind.title.lowercased())…"
        let configuration = MapConfiguration(mesh: meshKind, cuts: cuts, grouping: grouping,
                                             centerLongitude: centerLongitude, referenceDate: date)
        let cached = overlays[meshKind]
        let options = sceneOptions()
        buildTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (MyriaMap, [LayerPath], [Int])? in
                do {
                    let base = try cached ?? MeshOverlay(kind: configuration.mesh, data: data)
                    let map = MyriaMap(base: base, data: data, configuration: configuration)
                    let layers = map.scene(options).paths.map(LayerPath.init)
                    return (map, layers, map.groupColorSlots(slotCount: 5))
                } catch {
                    return nil
                }
            }.value
            guard !Task.isCancelled else { return }
            isBuilding = false
            guard let (map, layers, slots) = result else {
                status = "Could not build the map"
                return
            }
            overlays[configuration.mesh] = map.base
            self.map = map
            staticLayers = layers
            colorSlots = slots
            selectedGroup = nil
            hover = nil
            nightMinute = -1
            refreshNight()
            status = "\(map.mesh.faceCount) faces · \(map.projection.cutEdges.count) cuts · \(map.pieces().count) pieces"
        }
    }

    /// Scene options for the static layers (everything but night and labels).
    private func sceneOptions() -> SceneOptions {
        var options = SceneOptions(date: date, style: style)
        options.showNight = false
        options.showLabels = false
        options.showLand = display.land
        options.showCoastlines = display.coastlines
        options.showBorders = display.borders
        options.showCuts = display.cuts
        options.showMesh = display.mesh
        return options
    }

    private func refreshLayers() {
        guard let map else { return }
        staticLayers = map.scene(sceneOptions()).paths.map(LayerPath.init)
        nightMinute = -1
        refreshNight()
    }

    private func refreshNight() {
        guard let map else { return }
        guard display.night else {
            nightLayers = []
            return
        }
        let minute = Int(date.timeIntervalSince1970 / 60)
        guard minute != nightMinute else { return }
        nightMinute = minute
        nightLayers = map.nightLayers(date: date, style: style).map(LayerPath.init)
    }

    func labels() -> [SceneText] {
        guard let map, display.labels else { return [] }
        return map.labelTexts(SceneOptions(date: date, style: style))
    }

    func zoneColor(group: Int) -> Color {
        guard group >= 0, group < colorSlots.count else { return .gray }
        return Color(style.zoneColor(slot: colorSlots[group]))
    }

    /// Updates the hover state for a pointer at map point `q`.
    func hover(at q: Vec2, viewPoint: CGPoint) {
        guard let map, let hit = map.region(atMapPoint: q) else {
            hover = nil
            return
        }
        hover = HoverInfo(region: hit.region, location: hit.location,
                          group: map.grouping.groupOfRegion[hit.region.id], viewPoint: viewPoint)
    }

    /// Writes the current view of the map as SVG or PNG.
    func export(to url: URL) throws {
        guard let map else { return }
        var options = SceneOptions(date: date, style: style)
        options.showNight = display.night
        options.showLabels = display.labels
        options.showLand = display.land
        options.showCoastlines = display.coastlines
        options.showBorders = display.borders
        options.showCuts = display.cuts
        options.showMesh = display.mesh
        let scene = map.scene(options)
        if url.pathExtension.lowercased() == "png" {
            try BitmapRenderer.png(scene, width: 3200).write(to: url)
        } else {
            try SVGRenderer.render(scene, width: 3200, title: "Myriamap").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Zone groups sorted by current UTC offset, with a representative region.
    func zoneRows() -> [(group: ZoneGroup, region: TimeZoneRegion)] {
        guard let map else { return [] }
        let labelRegion = Dictionary(map.labels.map { ($0.group, $0.region) }, uniquingKeysWith: { a, _ in a })
        return map.grouping.groups
            .map { g in (g, map.atlas.regions[labelRegion[g.id] ?? g.primaryRegion]) }
            .sorted { ($0.1.utcOffset(at: date), $0.1.identifier) < ($1.1.utcOffset(at: date), $1.1.identifier) }
    }
}
