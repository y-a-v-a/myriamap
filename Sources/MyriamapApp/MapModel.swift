import AppKit
import MyriaGeometry
import Myriamap
import Observation
import SwiftUI
import ZoneAtlas

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
    var display = DisplayOptions()
    /// Whether the window is dark; follows the effective appearance.
    var dark = false
    /// The map's colour scheme (Settings, saved).
    var theme = MapModel.stored(MapTheme.self, key: "theme") ?? .standard {
        didSet {
            guard theme != oldValue else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
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
    var timeOffset: TimeInterval = 0 { didSet { clockChanged() } }
    var now = Date()
    /// `date` to the minute, as often as the map's clocks and night change.
    /// The map follows this rather than `now`, so the clock's tick only
    /// redraws what shows seconds.
    private(set) var minute = MapModel.minute(of: Date())
    /// The time the sidebar shows, to the minute like its clocks. It
    /// follows `date`, but while the time is scrubbed at most ten times a
    /// second: a list of clocks takes far longer to lay out than a frame of
    /// the map.
    private(set) var listDate = MapModel.minute(of: Date())
    /// 0 folds the map into a globe, 1 lays it flat.
    var unfold: Double = 1

    // Outputs.
    private(set) var map: MyriaMap?
    /// The map's geometry on the GPU.
    private(set) var gpuMap: GPUMap?
    /// Draws the map; nil until it is ready, or without a Metal device.
    private(set) var renderer: MetalMapRenderer?
    /// Counts finished builds, so views can tell when the map changed.
    private(set) var mapVersion = 0
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
    private var gpuMeshes: [MeshKind: GPUMesh] = [:]
    private var buildTask: Task<Void, Never>?
    private var clock: Timer?
    /// Clock labels for the minute and style they were made for.
    @ObservationIgnored private var labelCache: (key: LabelKey, texts: [SceneText])?
    /// `-unfold 0.4` on the command line starts partly folded.
    private var launchUnfold = UserDefaults.standard.string(forKey: "unfold").flatMap(Double.init)
    private var foldLink: CADisplayLink?
    @ObservationIgnored private var listDateUpdate: Task<Void, Never>?
    @ObservationIgnored private var listDateUpdated = Date.distantPast

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
                // Compiling the shaders overlaps with loading the data.
                async let renderer = Task.detached(priority: .userInitiated) { try? MetalMapRenderer() }.value
                let loaded = try await Task.detached(priority: .userInitiated) { try GeoData.bundled() }.value
                self.renderer = await renderer
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
        clockChanged()
    }

    private static func minute(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func clockChanged() {
        let minute = Self.minute(of: date)
        if minute != self.minute { self.minute = minute }
        updateListDate()
    }

    private func updateListDate() {
        let wait = 0.1 - Date().timeIntervalSince(listDateUpdated)
        guard wait > 0 else {
            listDateUpdated = Date()
            if minute != listDate { listDate = minute }
            return
        }
        guard listDateUpdate == nil else { return }
        listDateUpdate = Task {
            try? await Task.sleep(for: .seconds(wait))
            listDateUpdate = nil
            updateListDate()
        }
    }

    /// Re-cuts and unfolds the map for the current settings, off the main thread.
    func rebuild() {
        guard let data else { return }
        buildTask?.cancel()
        isBuilding = true
        status = "Unfolding \(meshKind.title.lowercased())…"
        let configuration = MapConfiguration(mesh: meshKind, cuts: cuts, grouping: grouping,
                                             centerLongitude: centerLongitude, referenceDate: date)
        let cached = overlays[meshKind], cachedMesh = gpuMeshes[meshKind], renderer = renderer
        buildTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (MyriaMap, GPUMap?)? in
                do {
                    let base = try cached ?? MeshOverlay(kind: configuration.mesh, data: data)
                    // The mesh's buffers serve every map cut from it; for a
                    // new mesh they are made while the map is cut.
                    async let mesh = renderer.map { try cachedMesh ?? $0.makeMesh(RenderMesh(base), kind: configuration.mesh) }
                    let map = MyriaMap(base: base, data: data, configuration: configuration)
                    return (map, try await mesh.flatMap { try renderer?.makeMap(map, mesh: $0) })
                } catch {
                    return nil
                }
            }.value
            guard !Task.isCancelled else { return }
            isBuilding = false
            guard let (map, gpuMap) = result else {
                status = "Could not build the map"
                return
            }
            overlays[configuration.mesh] = map.base
            gpuMeshes[configuration.mesh] = gpuMap?.mesh
            self.map = map
            self.gpuMap = gpuMap
            mapVersion += 1
            labelCache = nil
            colorSlots = map.colorSlots
            selectedGroup = nil
            hover = nil
            if let initial = launchUnfold {
                launchUnfold = nil
                unfold = initial
            }
            status = renderer == nil ? "This Mac has no Metal device to draw the map"
                : "\(map.mesh.faceCount) faces · \(map.projection.cutEdges.count) cuts · \(map.pieces().count) pieces"
        }
    }

    /// What the map view draws for a viewport.
    func frame(viewport: Viewport) -> MapFrame {
        // Night moves with the minute, like the clocks.
        var frame = MapFrame(viewport: viewport, contentsScale: 1, date: minute, style: style)
        frame.unfold = unfold
        frame.showNight = display.night
        frame.showLand = display.land
        frame.showCoastlines = display.coastlines
        frame.showBorders = display.borders
        frame.showCuts = display.cuts
        frame.showMesh = display.mesh
        if unfold >= 1 {
            if let hoverGroup, hoverGroup != selectedGroup {
                frame.highlights.append(.init(group: hoverGroup, width: 1.2))
            }
            if let selectedGroup { frame.highlights.append(.init(group: selectedGroup, width: 2)) }
            frame.labels = labels()
        }
        return frame
    }

    /// Animates from the globe to the flat map (or back when already flat),
    /// a step per displayed frame.
    func playFold() {
        foldLink?.invalidate()
        let from = unfold, to: Double = unfold >= 1 ? 0 : 1
        let duration = 3.5 * abs(to - from)
        var start: CFTimeInterval?
        isPlayingFold = true
        let step = FrameStep { [weak self] link in
            guard let self else { return link.invalidate() }
            let shown = link.targetTimestamp
            let t = min(1, (shown - (start ?? shown)) / max(duration, 0.01))
            if start == nil { start = shown }
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            unfold = from + (to - from) * eased
            if t >= 1 {
                link.invalidate()
                foldLink = nil
                isPlayingFold = false
            }
        }
        foldLink = NSScreen.main?.displayLink(target: step, selector: #selector(FrameStep.step(_:)))
        foldLink?.add(to: .main, forMode: .common)
        if foldLink == nil {
            unfold = to
            isPlayingFold = false
        }
    }

    private struct LabelKey: Equatable {
        let minute: Date
        let style: MapStyle
        let mapVersion: Int
    }

    /// Clock labels, remade when the minute, the colours or the map change.
    func labels() -> [SceneText] {
        guard let map, display.labels else { return [] }
        let key = LabelKey(minute: minute, style: style, mapVersion: mapVersion)
        if let labelCache, labelCache.key == key { return labelCache.texts }
        let texts = map.labelTexts(SceneOptions(date: minute, style: style))
        labelCache = (key, texts)
        return texts
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

    /// Zone groups sorted by their UTC offset at `listDate`, with a
    /// representative region.
    func zoneRows() -> [(group: ZoneGroup, region: TimeZoneRegion)] {
        guard let map else { return [] }
        let labelRegion = Dictionary(map.labels.map { ($0.group, $0.region) }, uniquingKeysWith: { a, _ in a })
        let date = listDate
        return map.grouping.groups
            .map { g in
                let region = map.atlas.regions[labelRegion[g.id] ?? g.primaryRegion]
                return (group: g, region: region, offset: region.utcOffset(at: date))
            }
            .sorted { ($0.offset, $0.region.identifier) < ($1.offset, $1.region.identifier) }
            .map { ($0.group, $0.region) }
    }
}

/// Calls back on every display link frame.
private final class FrameStep: NSObject {
    let body: @MainActor (CADisplayLink) -> Void

    init(_ body: @escaping @MainActor (CADisplayLink) -> Void) {
        self.body = body
    }

    @MainActor @objc func step(_ link: CADisplayLink) { body(link) }
}
