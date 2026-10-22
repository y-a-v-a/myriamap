import Myriamap
import SwiftUI
import UniformTypeIdentifiers
import ZoneAtlas

struct ContentView: View {
    @Bindable var model: MapModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            ZoneList(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            ZStack {
                MapCanvas(model: model)
                if model.map == nil {
                    ProgressView(model.status)
                }
            }
            .navigationTitle("Myriamap")
            .navigationSubtitle(model.status)
            .inspector(isPresented: $showInspector) {
                SettingsPanel(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 270)
            }
            .toolbar {
                ToolbarItemGroup {
                    TimeScrubber(model: model)
                    Button {
                        export()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export the map as SVG or PNG")
                    .disabled(model.map == nil)
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Settings", systemImage: "sidebar.trailing")
                    }
                    .help("Show or hide the settings")
                }
            }
        }
        .onAppear {
            model.dark = colorScheme == .dark
            model.start()
        }
        .onChange(of: colorScheme) { model.dark = colorScheme == .dark }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg, .png]
        panel.nameFieldStringValue = "myriamap.svg"
        panel.message = "Choose .svg for vector output or .png for a 3200 px image."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.export(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Every zone group with its current time, sorted by UTC offset. It
/// follows the model's `listDate`, which changes once a minute.
struct ZoneList: View {
    @Bindable var model: MapModel

    var body: some View {
        List(selection: $model.selectedGroup) {
            ForEach(model.zoneRows(), id: \.group.id) { row in
                ZoneRow(region: row.region, date: model.listDate, color: model.zoneColor(group: row.group.id),
                        memberCount: row.group.regions.count)
                    .tag(row.group.id)
            }
        }
    }
}

struct ZoneRow: View {
    let region: TimeZoneRegion
    let date: Date
    let color: Color
    let memberCount: Int

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 12, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(region.placeName + (memberCount > 1 ? " +\(memberCount - 1)" : ""))
                    .lineLimit(1)
                Text(region.offsetLabel(at: date) + dayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(region.clockTime(at: date))
                .font(.system(.title3, design: .rounded).weight(.medium))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var dayLabel: String {
        switch region.dayOffset(at: date) {
        case 1: " · tomorrow"
        case -1: " · yesterday"
        default: ""
        }
    }
}

/// Moves the displayed time up to a day either way.
struct TimeScrubber: View {
    @Bindable var model: MapModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            Slider(value: $model.timeOffset.snapped(to: 900), in: -86_400...86_400)
                .frame(width: 160)
                .help("Scrub through time to watch day and night move")
            Text(offsetText)
                .monospacedDigit()
                .frame(width: 64, alignment: .leading)
            Button("Now") { model.timeOffset = 0 }
                .disabled(model.timeOffset == 0)
        }
        // Keeps the icon clear of the toolbar's rounded glass background.
        .padding(.horizontal, 8)
    }

    private var offsetText: String {
        let minutes = Int(model.timeOffset / 60)
        if minutes == 0 { return "now" }
        return String(format: "%@%dh%02d", minutes > 0 ? "+" : "−", abs(minutes) / 60, abs(minutes) % 60)
    }
}

struct SettingsPanel: View {
    @Bindable var model: MapModel

    private static let meshes: [MeshKind] = [
        .graticule(step: 3.75), .graticule(step: 1.875), .graticule(step: 1.25), .graticule(step: 0.9375),
        .geodesic(frequency: 24), .geodesic(frequency: 40), .geodesic(frequency: 64),
    ]

    var body: some View {
        Form {
            Section("Cuts") {
                Picker("Cut along", selection: $model.cuts) {
                    Text("Timezone borders").tag(MapConfiguration.Cuts.timezones)
                    Text("Oceans (van Wijk)").tag(MapConfiguration.Cuts.landmass)
                }
                Picker("Borders", selection: $model.grouping) {
                    ForEach(CutGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(model.cuts != .timezones)
                VStack(alignment: .leading) {
                    Text("Centre longitude: \(Int(model.centerLongitude))°")
                    Slider(value: $model.centerLongitude.snapped(to: 5), in: -180...180) { editing in
                        if !editing { model.rebuild() }
                    }
                }
            }
            Section("Myriahedron") {
                Picker("Mesh", selection: $model.meshKind) {
                    ForEach(Self.meshes, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Faces are flat; each shows its part of the globe by gnomonic projection. "
                    + "Graticule steps that divide 7.5° align with the nautical timezone meridians.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Layers") {
                Toggle("Day and night", isOn: $model.display.night)
                Toggle("Clocks", isOn: $model.display.labels)
                Toggle("Land", isOn: $model.display.land)
                Toggle("Coastlines", isOn: $model.display.coastlines)
                Toggle("Timezone borders", isOn: $model.display.borders)
                Toggle("Cut edges", isOn: $model.display.cuts)
                Toggle("Faces", isOn: $model.display.mesh)
            }
            Section("Colours") {
                LabeledContent("Scheme", value: model.theme.title)
                SettingsLink {
                    Text("Appearance and Colours…")
                }
                .help("Choose light or dark and the colour scheme (⌘,)")
            }
            if model.isBuilding {
                Section { ProgressView().controlSize(.small) }
            }
            Section("Data") {
                Text("Timezones: timezone-boundary-builder 2026e (ODbL, © OpenStreetMap contributors). "
                    + "Land: Natural Earth (public domain).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension Binding where Value == Double {
    /// Rounds values set through the binding to multiples of `step`.
    /// Sliders use this instead of `step:`, which on macOS draws a tick mark
    /// per step and turns into a dashed line under the track.
    func snapped(to step: Double) -> Binding<Double> {
        Binding(get: { wrappedValue }, set: { wrappedValue = ($0 / step).rounded() * step })
    }
}
