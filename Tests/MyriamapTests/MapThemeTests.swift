import Foundation
import Testing
@testable import Myriamap

@Suite struct ColourMathTests {
    @Test func contrastRatioSpansOneToTwentyOne() {
        let black = RGBA(0, 0, 0), white = RGBA(1, 1, 1)
        #expect(abs(black.contrastRatio(with: white) - 21) < 1e-9)
        #expect(abs(white.contrastRatio(with: black) - 21) < 1e-9)
        #expect(abs(RGBA(hex: "#2a78d6").contrastRatio(with: RGBA(hex: "#2a78d6")) - 1) < 1e-9)
        // WCAG reference value: #777777 on white is about 4.48:1.
        #expect(abs(RGBA(hex: "#777777").contrastRatio(with: white) - 4.48) < 0.01)
    }

    @Test func perceptualDistanceIsOKLab() {
        let black = RGBA(0, 0, 0), white = RGBA(1, 1, 1)
        #expect(abs(black.perceptualDistance(to: white) - 100) < 0.01)
        #expect(white.oklab.a.magnitude < 1e-4 && white.oklab.b.magnitude < 1e-4)
        // Distance is symmetric and zero on the diagonal.
        let blue = RGBA(hex: "#2a78d6"), orange = RGBA(hex: "#eb6834")
        #expect(abs(blue.perceptualDistance(to: orange) - orange.perceptualDistance(to: blue)) < 1e-12)
        #expect(blue.perceptualDistance(to: blue) == 0)
    }

    @Test func compositingHonoursAlpha() {
        let grey = RGBA(0, 0, 0, 0.5).composited(over: RGBA(1, 1, 1))
        #expect(abs(grey.r - 0.5) < 1e-12 && abs(grey.g - 0.5) < 1e-12 && grey.a == 1)
        #expect(RGBA(hex: "#eb6834").composited(over: RGBA(1, 1, 1)) == RGBA(hex: "#eb6834"))
    }
}

@Suite struct MapThemeTests {
    /// Every background a label can sit on: each zone fill, with land on
    /// top, and with up to three stacked night layers (civil, nautical,
    /// astronomical twilight).
    static func labelBackgrounds(_ style: MapStyle) -> [RGBA] {
        (0..<MapStyle.slotCount).flatMap { slot -> [RGBA] in
            let fill = style.zoneColor(slot: slot)
            var layers = [fill, style.land.composited(over: fill)]
            for _ in 0..<3 { layers.append(style.night.composited(over: layers.last!)) }
            return layers
        }
    }

    @Test(arguments: MapTheme.allCases, [false, true])
    func labelInksStayLegible(theme: MapTheme, dark: Bool) {
        let style = theme.style(dark: dark)
        for background in Self.labelBackgrounds(style) {
            // Clock (bold), place name, UTC offset.
            #expect(style.primaryInk.contrastRatio(with: background) >= 4.5, "\(theme) clock on \(background.hex)")
            #expect(style.secondaryInk.contrastRatio(with: background) >= 4.0, "\(theme) place on \(background.hex)")
            #expect(style.mutedInk.contrastRatio(with: background) >= 3.0, "\(theme) offset on \(background.hex)")
        }
    }

    @Test(arguments: MapTheme.allCases, [false, true])
    func zoneFillsAreDistinct(theme: MapTheme, dark: Bool) {
        let style = theme.style(dark: dark)
        #expect(style.zoneSlots.count >= MapStyle.slotCount)
        // Any two slots can end up side by side, so check every pair.
        let fills = (0..<MapStyle.slotCount).map(style.zoneColor(slot:))
        for i in fills.indices {
            for j in fills.indices where j > i {
                #expect(fills[i].perceptualDistance(to: fills[j]) >= 5, "\(theme) \(fills[i].hex) vs \(fills[j].hex)")
            }
        }
    }

    @Test(arguments: MapTheme.allCases)
    func darkVariantIsDark(theme: MapTheme) {
        let light = theme.style(dark: false), dark = theme.style(dark: true)
        #expect(dark.page.relativeLuminance < 0.05)
        #expect(light.page.relativeLuminance > 0.8)
        #expect(dark.primaryInk.relativeLuminance > dark.page.relativeLuminance)
        #expect(light.primaryInk.relativeLuminance < light.page.relativeLuminance)
    }

    @Test func themesHaveStableNames() {
        #expect(MapTheme.allCases.map(\.rawValue) == ["standard", "atlas", "blueprint"])
        #expect(Set(MapTheme.allCases.map(\.title)).count == MapTheme.allCases.count)
        for theme in MapTheme.allCases { #expect(MapTheme(rawValue: theme.rawValue) == theme) }
        #expect(MapStyle.light == MapTheme.standard.style(dark: false))
        #expect(MapStyle.dark == MapTheme.standard.style(dark: true))
        // The themes differ from each other in both variants.
        for dark in [false, true] {
            #expect(Set(MapTheme.allCases.map { $0.style(dark: dark) }).count == MapTheme.allCases.count)
        }
    }

    @Test(arguments: MapTheme.allCases)
    func scenesPaintWithTheTheme(theme: MapTheme) {
        let style = theme.style(dark: true)
        let scene = Fixture.map.scene(SceneOptions(date: Fixture.date, style: style))
        #expect(scene.background == style.page)
        let zoneFills = Set(scene.paths.filter { $0.role == .zone }.compactMap(\.fill))
        let themeFills = Set((0..<MapStyle.slotCount).map(style.zoneColor(slot:)))
        #expect(!zoneFills.isEmpty && zoneFills.isSubset(of: themeFills))
        #expect(scene.texts.contains { $0.color == style.primaryInk })
        let folded = Fixture.map.foldedScene(unfold: 0.5, folding: Fixture.map.folding(),
                                             options: SceneOptions(date: Fixture.date, style: style))
        #expect(folded.background == style.page)
    }
}
