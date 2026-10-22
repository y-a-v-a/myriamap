import AppKit
import MetalKit
import Myriamap
import SwiftUI

/// The map, drawn with Metal: fills, lines, day and night, outlines and
/// clocks. It draws only when what it shows changes; panning, zooming,
/// folding and moving through time change a few numbers, not the geometry.
struct MetalMapView: NSViewRepresentable {
    let renderer: MetalMapRenderer
    let map: GPUMap?
    let frame: MapFrame

    func makeNSView(context: Context) -> MapMetalView { MapMetalView(renderer: renderer) }

    func updateNSView(_ view: MapMetalView, context: Context) {
        view.show(frame, map: map)
    }
}

final class MapMetalView: MTKView, MTKViewDelegate {
    private let renderer: MetalMapRenderer
    private var shown: MapFrame?
    private var map: GPUMap?

    init(renderer: MetalMapRenderer) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = renderer.pixelFormat
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        renderer.labelsDidChange = { [weak self] in self?.needsDisplay = true }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pointer events belong to the SwiftUI view around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ frame: MapFrame, map: GPUMap?) {
        guard frame != shown || map !== self.map else { return }
        shown = frame
        self.map = map
        needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        guard var frame = shown, bounds.width > 0, let drawable = currentDrawable,
              let commandBuffer = renderer.makeCommandBuffer()
        else { return }
        frame.contentsScale = drawableSize.width / bounds.width
        renderer.encode(frame, map: map, into: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
