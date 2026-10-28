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
    /// The drawable size of the last frame drawn.
    private var drawnSize = CGSize.zero

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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A panel sliding in or out resizes the view at every step, more
        // often than the window gets round to displaying it: each size is
        // drawn at once, or the layer stretches the last frame to fit.
        if window != nil, drawableSize != drawnSize { draw() }
    }

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
        // A frame for a new size goes out with the resize itself, not a
        // frame after it.
        presentsWithTransaction = drawableSize != drawnSize
        drawnSize = drawableSize
        if presentsWithTransaction {
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            drawable.present()
        } else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
