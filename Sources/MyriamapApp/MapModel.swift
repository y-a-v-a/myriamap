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
    /// Whether the window is dark; follows the effective appearance.
    var dark = false { didSet { if dark != oldValue { refreshLayers() } } }
    /// The map's colour scheme (Settings, saved).
    var theme = MapModel.stored(MapTheme.self, key: "theme") ?? .standard {
        didSet {
            guard theme != oldValue else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            refreshLayers()
        }
    }
    /// Light, dark or following the system (Settings, saved).
    var appearance = MapModel.stored(AppearanceMode.self, key: "appearance") ?? .system {
        didSet {
            guard appearance != oldValue else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            NSApplication.shared.appearance = appearance.nsAppearance
        }
    }
    /// Offset from the real clock, for scrubbing through the day.
    var timeOffset: TimeInterval = 0 { didSet { refreshNight() } }
    var now = Date()
    /// 0 folds the map into a globe, 1 lays it flat.
    var unfold: Double = 1 { didSet { if unfold != oldValue { refreshFolded() } } }

    // Outputs.
    private(set) var map: MyriaMap?
    /// Counts finished builds, so views can tell when the map changed.
    private(set) var mapVersion = 0
    private(set) var staticLayers: [LayerPath] = []
    private(set) var nightLayers: [LayerPath] = []
    private(set) var foldedLayers: [LayerPath] = []
    private(set) var isPlayingFold = false
    private(set) var colorSlots: [Int] = []
    private(set) var isBuilding = false
    private(set) var status = "Loading timezone data…"
    var hover: HoverInfo? {
        didSet { if hover?.group != hoverGroup { hoverGroup = hover?.group } }
    }
    /// The group under the pointer. Unlike `hover` it only changes when the
    /// pointer crosses into another group, so its outline isn't redrawn on
    /// every move.
    private(set) var hoverGroup: Int?
    var selectedGroup: Int?

    private var data: GeoData?
    private var overlays: [MeshKind: MeshOverlay] = [:]
    private var buildTask: Task<Void, Never>?
    private var nightMinute = -1
    private var clock: Timer?
    private var folding: Folding?
    /// The folded frame being built off the main thread, if any.
    private var foldTask: Task<Void, Never>?
    /// The fold or its inputs changed while a frame was being built.
    private var foldIsStale = false
    /// Group outlines for the current map, built on first use.
    @ObservationIgnored private var outlines: [Int: Path] = [:]
    /// `-unfold 0.4` on the command line starts partly folded.
    private var launchUnfold = UserDefaults.standard.string(forKey: "unfold").flatMap(Double.init)
    private var foldTimer: Timer?

    var date: Date { now.addingTimeInterval(timeOffset) }
    var style: MapStyle { theme.style(dark: dark) }

    init() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    /// A saved setting (also settable for one launch: `-theme atlas`).
    nonisolated private static func stored<T: RawRepresentable<String>>(_: T.Type, key: String) -> T? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        return T(rawValue: raw)
    }

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
                    return (map, layers, map.colorSlots)
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
            mapVersion += 1
            folding = nil
            outlines = [:]
            // Colours or layers may have changed while the map was building.
            staticLayers = options == sceneOptions() ? layers : map.scene(sceneOptions()).paths.map(LayerPath.init)
            colorSlots = slots
            selectedGroup = nil
            hover = nil
            nightMinute = -1
            refreshNight()
            if let initial = launchUnfold {
                launchUnfold = nil
                unfold = initial
            }
            refreshFolded()
            status = "\(map.mesh.faceCount) faces · \(map.projection.cutEdges.count) cuts · \(map.pieces().count) pieces"
        }
    }

    /// Scene options for the static layers (everything but night and labels,
    /// so the date doesn't matter and is fixed).
    private func sceneOptions() -> SceneOptions {
        var options = SceneOptions(date: .distantPast, style: style)
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
        refreshFolded()
    }

    /// Builds the folded layers off the main thread, one frame at a time.
    /// Changes made meanwhile are picked up when the frame is done, so the
    /// slider and the animation never queue up work or block the window.
    private func refreshFolded() {
        guard let map, unfold < 1 else {
            foldedLayers = []
            return
        }
        guard foldTask == nil else {
            foldIsStale = true
            return
        }
        let cached = folding, unfold = unfold, version = mapVersion
        var options = SceneOptions(date: date, style: style)
        options.showLand = display.land
        foldTask = Task {
            let (folding, layers) = await Task.detached(priority: .userInitiated) { [options] in
                let folding = cached ?? map.folding()
                return (folding, map.foldedScene(unfold: unfold, folding: folding, options: options).paths.map(LayerPath.init))
            }.value
            foldTask = nil
            // A frame for a map that has since been rebuilt is dropped.
            if version == mapVersion {
                self.folding = folding
                if self.unfold < 1 { foldedLayers = layers }
            }
            if foldIsStale {
                foldIsStale = false
                refreshFolded()
            }
        }
    }

    /// Animates from the globe to the flat map (or back when already flat).
    func playFold() {
        foldTimer?.invalidate()
        let start = Date(), from = unfold, to: Double = unfold >= 1 ? 0 : 1
        let duration = 3.5 * abs(to - from)
        isPlayingFold = true
        foldTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(1, Date().timeIntervalSince(start) / max(duration, 0.01))
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                self.unfold = from + (to - from) * eased
                if t >= 1 {
                    self.foldTimer?.invalidate()
                    self.foldTimer = nil
                    self.isPlayingFold = false
                }
            }
        }
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

    /// The outline of a zone group in map coordinates.
    func outline(ofGroup g: Int) -> Path? {
        guard let map else { return nil }
        if let path = outlines[g] { return path }
        let path = Path { p in
            for line in map.outline(ofGroup: g) { p.addLines(line.map { CGPoint(x: $0.x, y: $0.y) }) }
        }
        outlines[g] = path
        return path
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

    /// The map drawn in every theme, for the previews in Settings.
    func themePreviews(dark: Bool, width: Int) async -> [MapTheme: CGImage] {
        guard let map else { return [:] }
        return await Task.detached(priority: .utility) {
            var previews: [MapTheme: CGImage] = [:]
            for theme in MapTheme.allCases {
                // Fills only, in daylight: at this size lines turn into speckles.
                var options = SceneOptions(style: theme.style(dark: dark))
                options.showLabels = false
                options.showNight = false
                options.showCoastlines = false
                options.showBorders = false
                previews[theme] = try? BitmapRenderer.image(map.scene(options), width: width)
            }
            return previews
        }.value
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
