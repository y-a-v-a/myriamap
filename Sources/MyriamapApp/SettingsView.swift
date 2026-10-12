import AppKit
import Myriamap
import SwiftUI

/// The app's appearance: follow the system, or force light or dark.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The Settings window (⌘,): appearance and colour scheme.
struct SettingsView: View {
    @Bindable var model: MapModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var previews: [MapTheme: CGImage] = [:]

    private struct PreviewKey: Equatable {
        let mapVersion: Int
        let dark: Bool
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("System follows the macOS setting. The map has a light and a dark variant of each colour scheme.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(MapTheme.allCases, id: \.self) { theme in
                        ThemeCard(theme: theme, style: theme.style(dark: colorScheme == .dark),
                                  preview: previews[theme], isSelected: model.theme == theme) {
                            model.theme = theme
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Colour scheme")
            } footer: {
                Text("Also used for exported SVG and PNG files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: PreviewKey(mapVersion: model.mapVersion, dark: colorScheme == .dark)) {
            // Drawn at 4× and scaled down, so lines come out fine.
            previews = await model.themePreviews(dark: colorScheme == .dark, width: 760)
        }
    }
}

/// One colour scheme: a preview of the map in it, its name and its zone colours.
struct ThemeCard: View {
    let theme: MapTheme
    let style: MapStyle
    let preview: CGImage?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color(style.page)
                    if let preview {
                        Image(decorative: preview, scale: 4)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    } else {
                        // Until the map is built: the zone colours as gores.
                        HStack(spacing: 3) {
                            ForEach(0..<MapStyle.slotCount, id: \.self) { slot in
                                Capsule().fill(Color(style.zoneColor(slot: slot)))
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                    }
                }
                .aspectRatio(2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack(spacing: 4) {
                    Text(theme.title).font(.headline)
                    Spacer()
                    ForEach(0..<MapStyle.slotCount, id: \.self) { slot in
                        Circle().fill(Color(style.zoneColor(slot: slot))).frame(width: 9, height: 9)
                    }
                }
                Text(theme.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title): \(theme.summary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
