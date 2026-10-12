import Foundation

/// An sRGB colour with alpha, components in 0...1.
public struct RGBA: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// From "#rrggbb".
    public init(hex: String, alpha: Double = 1) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(s, radix: 16) ?? 0
        self.init(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255, alpha)
    }

    public var hex: String {
        String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    /// Linear blend towards `other` by `t` (0 keeps self).
    public func mixed(with other: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
    }

    /// `self` painted over an opaque `background`, honouring alpha.
    public func composited(over background: RGBA) -> RGBA {
        RGBA(r * a + background.r * (1 - a), g * a + background.g * (1 - a), b * a + background.b * (1 - a))
    }

    /// WCAG relative luminance (alpha ignored).
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrastRatio(with other: RGBA) -> Double {
        let (x, y) = (relativeLuminance, other.relativeLuminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// OKLab coordinates (L, a, b), alpha ignored.
    public var oklab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Perceptual difference: Euclidean OKLab distance ×100 (black to
    /// white is 100; below about 5 neighbours start to look alike).
    public func perceptualDistance(to other: RGBA) -> Double {
        let (p, q) = (oklab, other.oklab)
        return 100 * ((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b)).squareRoot()
    }
}

/// Colours for one appearance (light or dark) of a theme.
public struct MapStyle: Hashable, Sendable {
    public var page: RGBA
    public var surface: RGBA
    /// Label inks: clock, place name, UTC offset. They sit on the zone
    /// fills, so each must stay legible over every slot with land and full
    /// night on top (`MapThemeTests` checks this).
    public var primaryInk: RGBA
    public var secondaryInk: RGBA
    public var mutedInk: RGBA
    /// Fill hues for zones, in fixed slot order; neighbouring zones get
    /// different slots.
    public var zoneSlots: [RGBA]
    /// How far zone hues are blended towards the surface (0 = full colour).
    public var zoneTint: Double
    public var land: RGBA
    public var coastline: RGBA
    public var border: RGBA
    public var cut: RGBA
    public var mesh: RGBA
    public var night: RGBA
    public var highlight: RGBA

    /// Zone slots in use: the graph colouring of the zones needs five.
    public static let slotCount = 5

    /// The standard theme, light.
    public static let light = MapTheme.standard.style(dark: false)
    /// The standard theme, dark.
    public static let dark = MapTheme.standard.style(dark: true)

    public func zoneColor(slot: Int) -> RGBA {
        zoneSlots[slot % zoneSlots.count].mixed(with: surface, zoneTint).withAlpha(1)
    }
}

/// A named colour scheme with a light and a dark variant.
public enum MapTheme: String, CaseIterable, Sendable {
    /// Clear, distinct hues from the reference data-viz palette.
    case standard
    /// Muted inks on paper, like a printed atlas.
    case atlas
    /// Shades of blue with pale linework, like a technical drawing.
    case blueprint

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .atlas: "Atlas"
        case .blueprint: "Blueprint"
        }
    }

    public var summary: String {
        switch self {
        case .standard: "Clear, distinct hues"
        case .atlas: "Muted inks on paper, like a printed atlas"
        case .blueprint: "Shades of blue with pale linework"
        }
    }

    public func style(dark: Bool) -> MapStyle {
        switch (self, dark) {
        case (.standard, false):
            MapStyle(
                page: RGBA(hex: "#f9f9f7"), surface: RGBA(hex: "#fcfcfb"),
                primaryInk: RGBA(hex: "#0b0b0b"), secondaryInk: RGBA(hex: "#2a2a2a"), mutedInk: RGBA(hex: "#3e3e3d"),
                zoneSlots: ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#6250d6", "#008300", "#e34948"]
                    .map { RGBA(hex: $0) },
                zoneTint: 0.62,
                land: RGBA(hex: "#0b0b0b", alpha: 0.17), coastline: RGBA(hex: "#52514e", alpha: 0.75),
                border: RGBA(hex: "#fcfcfb", alpha: 0.95), cut: RGBA(hex: "#898781", alpha: 0.9),
                mesh: RGBA(hex: "#0b0b0b", alpha: 0.10), night: RGBA(hex: "#0d366b", alpha: 0.09),
                highlight: RGBA(hex: "#0b0b0b", alpha: 0.85))
        case (.standard, true):
            MapStyle(
                page: RGBA(hex: "#0d0d0d"), surface: RGBA(hex: "#1a1a19"),
                primaryInk: RGBA(hex: "#f0efec"), secondaryInk: RGBA(hex: "#d8d8d5"), mutedInk: RGBA(hex: "#bbbab7"),
                zoneSlots: ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#9085e9", "#008300", "#e66767"]
                    .map { RGBA(hex: $0) },
                zoneTint: 0.38,
                land: RGBA(hex: "#0d0d0d", alpha: 0.28), coastline: RGBA(hex: "#f0efec", alpha: 0.45),
                border: RGBA(hex: "#1a1a19", alpha: 0.95), cut: RGBA(hex: "#898781", alpha: 0.9),
                mesh: RGBA(hex: "#f0efec", alpha: 0.08), night: RGBA(hex: "#000000", alpha: 0.2),
                highlight: RGBA(hex: "#f0efec", alpha: 0.85))
        case (.atlas, false):
            MapStyle(
                page: RGBA(hex: "#f1ebdc"), surface: RGBA(hex: "#f7f2e6"),
                primaryInk: RGBA(hex: "#1f1a15"), secondaryInk: RGBA(hex: "#35302a"), mutedInk: RGBA(hex: "#48433d"),
                zoneSlots: ["#8fb07c", "#d98c63", "#dcb65a", "#7f9fc6", "#bd8fb6"].map { RGBA(hex: $0) },
                zoneTint: 0.36,
                land: RGBA(hex: "#5b4a35", alpha: 0.13), coastline: RGBA(hex: "#5b4a35", alpha: 0.7),
                border: RGBA(hex: "#f7f2e6", alpha: 0.95), cut: RGBA(hex: "#9a8f7c", alpha: 0.9),
                mesh: RGBA(hex: "#1f1a15", alpha: 0.10), night: RGBA(hex: "#1d2b4a", alpha: 0.08),
                highlight: RGBA(hex: "#1f1a15", alpha: 0.85))
        case (.atlas, true):
            MapStyle(
                page: RGBA(hex: "#14110d"), surface: RGBA(hex: "#1f1b15"),
                primaryInk: RGBA(hex: "#f6efe0"), secondaryInk: RGBA(hex: "#dad3c6"), mutedInk: RGBA(hex: "#beb8ab"),
                zoneSlots: ["#6a8c5b", "#b06744", "#a8853a", "#5a7ba3", "#8f6288"].map { RGBA(hex: $0) },
                zoneTint: 0.36,
                land: RGBA(hex: "#14110d", alpha: 0.25), coastline: RGBA(hex: "#f6efe0", alpha: 0.4),
                border: RGBA(hex: "#1f1b15", alpha: 0.95), cut: RGBA(hex: "#8c8273", alpha: 0.9),
                mesh: RGBA(hex: "#f6efe0", alpha: 0.08), night: RGBA(hex: "#000000", alpha: 0.2),
                highlight: RGBA(hex: "#f6efe0", alpha: 0.85))
        case (.blueprint, false):
            MapStyle(
                page: RGBA(hex: "#edf3f9"), surface: RGBA(hex: "#f5f9fc"),
                primaryInk: RGBA(hex: "#0a2540"), secondaryInk: RGBA(hex: "#163049"), mutedInk: RGBA(hex: "#2b435a"),
                zoneSlots: ["#6b8ff0", "#5f9ca8", "#a7a6e0", "#62d5ef", "#1a8fd4"].map { RGBA(hex: $0) },
                zoneTint: 0.45,
                land: RGBA(hex: "#0a2540", alpha: 0.11), coastline: RGBA(hex: "#0a2540", alpha: 0.6),
                border: RGBA(hex: "#f5f9fc", alpha: 0.95), cut: RGBA(hex: "#5d7a99", alpha: 0.9),
                mesh: RGBA(hex: "#0a2540", alpha: 0.10), night: RGBA(hex: "#0a2540", alpha: 0.07),
                highlight: RGBA(hex: "#0a2540", alpha: 0.85))
        case (.blueprint, true):
            MapStyle(
                page: RGBA(hex: "#0a2240"), surface: RGBA(hex: "#0e2b4f"),
                primaryInk: RGBA(hex: "#f2f7ff"), secondaryInk: RGBA(hex: "#dbe3ed"), mutedInk: RGBA(hex: "#bbc6d5"),
                zoneSlots: ["#173c94", "#56607f", "#5a5cc6", "#1b7aa8", "#0a5762"].map { RGBA(hex: $0) },
                zoneTint: 0.22,
                land: RGBA(hex: "#ffffff", alpha: 0.06), coastline: RGBA(hex: "#e6f0ff", alpha: 0.75),
                border: RGBA(hex: "#d6e8ff", alpha: 0.5), cut: RGBA(hex: "#8fb3dc", alpha: 0.9),
                mesh: RGBA(hex: "#e6f0ff", alpha: 0.1), night: RGBA(hex: "#020b18", alpha: 0.2),
                highlight: RGBA(hex: "#ffffff", alpha: 0.9))
        }
    }
}
