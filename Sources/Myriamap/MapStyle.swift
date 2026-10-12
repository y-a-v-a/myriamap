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
}

/// Colours for one appearance (light or dark).
public struct MapStyle: Hashable, Sendable {
    public var page: RGBA
    public var surface: RGBA
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

    /// Reference data-viz palette, light surface.
    public static let light = MapStyle(
        page: RGBA(hex: "#f9f9f7"), surface: RGBA(hex: "#fcfcfb"),
        primaryInk: RGBA(hex: "#0b0b0b"), secondaryInk: RGBA(hex: "#52514e"), mutedInk: RGBA(hex: "#898781"),
        zoneSlots: ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#6250d6", "#008300", "#e34948"]
            .map { RGBA(hex: $0) },
        zoneTint: 0.62,
        land: RGBA(hex: "#0b0b0b", alpha: 0.17), coastline: RGBA(hex: "#52514e", alpha: 0.75),
        border: RGBA(hex: "#fcfcfb", alpha: 0.95), cut: RGBA(hex: "#898781", alpha: 0.9),
        mesh: RGBA(hex: "#0b0b0b", alpha: 0.10), night: RGBA(hex: "#0d366b", alpha: 0.09),
        highlight: RGBA(hex: "#0b0b0b", alpha: 0.85))

    /// Reference data-viz palette, dark surface.
    public static let dark = MapStyle(
        page: RGBA(hex: "#0d0d0d"), surface: RGBA(hex: "#1a1a19"),
        primaryInk: RGBA(hex: "#f0efec"), secondaryInk: RGBA(hex: "#c3c2b7"), mutedInk: RGBA(hex: "#898781"),
        zoneSlots: ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#9085e9", "#008300", "#e66767"]
            .map { RGBA(hex: $0) },
        zoneTint: 0.38,
        land: RGBA(hex: "#0d0d0d", alpha: 0.28), coastline: RGBA(hex: "#f0efec", alpha: 0.45),
        border: RGBA(hex: "#1a1a19", alpha: 0.95), cut: RGBA(hex: "#898781", alpha: 0.9),
        mesh: RGBA(hex: "#f0efec", alpha: 0.08), night: RGBA(hex: "#000000", alpha: 0.2),
        highlight: RGBA(hex: "#f0efec", alpha: 0.85))

    public func zoneColor(slot: Int) -> RGBA {
        zoneSlots[slot % zoneSlots.count].mixed(with: surface, zoneTint).withAlpha(1)
    }
}
