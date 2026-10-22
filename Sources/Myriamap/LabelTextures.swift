#if canImport(Metal) && canImport(CoreText)
#if canImport(AppKit)
import AppKit
#endif
import CoreGraphics
import CoreText
import Foundation
import Metal
import MyriaGeometry

/// Label text rasterised with Core Text into small textures, cached by
/// text, weight and size. Sizes come in steps of a sixteenth of an octave,
/// so a label is never scaled by more than about 2 %.
///
/// Missing textures are rasterised in the background. Until they arrive,
/// each label keeps showing what it showed before (the previous minute, or
/// the previous size while zooming), so drawing never waits for text.
final class LabelTextures: @unchecked Sendable {
    struct Key: Hashable {
        let text: String
        let bold: Bool
        let step: Int
    }

    final class Entry {
        let texture: MTLTexture
        /// Font size in pixels.
        let size: Double
        /// The text's box inside the texture, pixels from the top left.
        let box: CGRect
        var lastUsed = 0

        init(texture: MTLTexture, size: Double, box: CGRect) {
            self.texture = texture
            self.size = size
            self.box = box
        }
    }

    static let stepsPerOctave = 16.0
    /// The largest size rasterised, 512 pixels; larger text is scaled up.
    static let largestStep = 9 * 16
    /// Labels smaller than this many points are not drawn.
    static let smallestPoints = 7.0

    let device: MTLDevice
    var onReady: (@MainActor () -> Void)?
    private var cache: [Key: Entry] = [:]
    private var pending: Set<Key> = []
    /// What each label showed last, and where on the map it was.
    private var shown: [Int: (key: Key, position: Vec2)] = [:]
    private var frameNumber = 0
    private var bytes = 0
    private let queue = DispatchQueue(label: "Myriamap.labels", qos: .userInitiated)

    init(device: MTLDevice) {
        self.device = device
    }

    static func step(forPixels size: Double) -> Int {
        min(Int((log2(max(size, 1)) * stepsPerOctave).rounded()), largestStep)
    }

    static func pixels(ofStep step: Int) -> Double { pow(2, Double(step) / stepsPerOctave) }

    /// The visible labels of a frame: where each goes and what it shows.
    /// Requests the textures it lacks.
    func quads(for frame: MapFrame) -> [(LabelQuad, MTLTexture)] {
        frameNumber += 1
        var out: [(LabelQuad, MTLTexture)] = []
        var missing: [Key] = []
        for (slot, wanted, center, pixels, color) in visible(frame) {
            var key = wanted
            let position = frame.labels[slot].position
            if cache[key] == nil {
                missing.append(key)
                // The same label, not a slot that a rebuilt map gave to another.
                guard let fallback = shown[slot], fallback.position == position, cache[fallback.key] != nil
                else { continue }
                key = fallback.key
            }
            let entry = cache[key]!
            shown[slot] = (key, position)
            entry.lastUsed = frameNumber
            let k = pixels / entry.size
            var origin = SIMD2(Float(center.x - entry.box.midX * k), Float(center.y - entry.box.midY * k))
            // At its own size, text sits on whole pixels so it stays crisp.
            if abs(k - 1) < 0.03 { origin = origin.rounded(.toNearestOrAwayFromZero) }
            let size = SIMD2(Float(Double(entry.texture.width) * k), Float(Double(entry.texture.height) * k))
            out.append((LabelQuad(origin: origin, size: size, color: color.simd), entry.texture))
        }
        request(missing)
        evict()
        return out
    }

    /// Rasterises everything a frame needs, here and now.
    func prepare(for frame: MapFrame) {
        for (_, key, _, _, _) in visible(frame) where cache[key] == nil {
            if let entry = Self.rasterize(key, device: device) { insert(key, entry) }
        }
    }

    private func visible(_ frame: MapFrame) -> [(slot: Int, key: Key, center: Vec2, pixels: Double, color: RGBA)] {
        let vp = frame.viewport, scale = frame.contentsScale
        let width = vp.size.x * scale, height = vp.size.y * scale
        var out: [(Int, Key, Vec2, Double, RGBA)] = []
        for (slot, text) in frame.labels.enumerated() {
            let points = text.size * vp.scale
            guard points >= Self.smallestPoints else { continue }
            let pixels = points * scale
            let center = vp.toView(text.position) * scale
            // Generous bounds: system digits are well under a font size wide.
            let halfWidth = pixels * (0.4 * Double(text.text.count) + 1), halfHeight = pixels
            guard center.x + halfWidth >= 0, center.x - halfWidth <= width,
                  center.y + halfHeight >= 0, center.y - halfHeight <= height else { continue }
            let key = Key(text: text.text, bold: text.weight == .bold, step: Self.step(forPixels: pixels))
            out.append((slot, key, center, pixels, text.color))
        }
        return out
    }

    private func request(_ keys: [Key]) {
        let new = keys.filter { pending.insert($0).inserted }
        guard !new.isEmpty else { return }
        let device = device
        queue.async {
            let made = new.map { ($0, Self.rasterize($0, device: device)) }
            DispatchQueue.main.async {
                for (key, entry) in made {
                    self.pending.remove(key)
                    if let entry { self.insert(key, entry) }
                }
                MainActor.assumeIsolated { self.onReady?() }
            }
        }
    }

    private func insert(_ key: Key, _ entry: Entry) {
        entry.lastUsed = frameNumber
        if let old = cache.updateValue(entry, forKey: key) { bytes -= old.texture.allocatedSize }
        bytes += entry.texture.allocatedSize
    }

    /// Drops the least recently used textures beyond a budget.
    private func evict(budget: Int = 48 << 20) {
        guard bytes > budget else { return }
        for (key, entry) in cache.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            guard bytes > budget * 3 / 4, entry.lastUsed < frameNumber else { break }
            cache[key] = nil
            bytes -= entry.texture.allocatedSize
        }
    }

    // MARK: Rasterising

    private static let fonts = FontCache()

    static func rasterize(_ key: Key, device: MTLDevice) -> Entry? {
        let size = pixels(ofStep: key.step)
        let font = fonts.font(size: size, bold: key.bold)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, key.text as CFString, attributes) else { return nil }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let pad = 2.0
        let width = Int((advance + 2 * pad).rounded(.up)), height = Int((ascent + descent + 2 * pad).rounded(.up))
        // Coverage straight into an alpha mask, which Core Text renders with
        // the same weight as text drawn onto a background.
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: nil, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.alphaOnly.rawValue)),
              let data = context.data
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line, context)

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        // The bitmap's first row is the top of the image, as in the texture.
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data,
                        bytesPerRow: context.bytesPerRow)
        return Entry(texture: texture, size: size, box: CGRect(x: pad, y: pad, width: advance, height: ascent + descent))
    }

    /// The system font with tabular digits, regular or semibold, per size.
    final class FontCache: @unchecked Sendable {
        private var fonts: [Double: CTFont] = [:]
        private let lock = NSLock()

        func font(size: Double, bold: Bool) -> CTFont {
            lock.lock()
            defer { lock.unlock() }
            let key = bold ? -size : size
            if let font = fonts[key] { return font }
            #if canImport(AppKit)
            // What SwiftUI's .system(size:weight:).monospacedDigit() uses.
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular) as CTFont
            #else
            let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let features = [[kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                             kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector]] as CFArray
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(base), [kCTFontFeatureSettingsAttribute: features] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            #endif
            fonts[key] = font
            return font
        }
    }
}
#endif
