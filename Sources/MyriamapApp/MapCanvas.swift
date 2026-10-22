import AppKit
import MyriaGeometry
import Myriamap
import SwiftUI
import ZoneAtlas

/// The unfolded map: static layers, day/night, live clocks, hover and
/// selection, with pinch/⌘-scroll/drag/double-click navigation.
struct MapCanvas: View {
    @Bindable var model: MapModel
    @State private var viewport: Viewport?
    @State private var dragStart: Vec2?
    @State private var pinchStart: (zoom: Double, center: Vec2)?

    var body: some View {
        GeometryReader { geometry in
            let size = Vec2(geometry.size.width, geometry.size.height)
            let view = currentViewport(size: size)
            ZStack(alignment: .topLeading) {
                if let renderer = model.renderer {
                    MetalMapView(renderer: renderer, map: model.gpuMap, frame: model.frame(viewport: view))
                } else {
                    Color(model.style.page)
                }
                if let hover = model.hover {
                    HoverCard(info: hover, date: model.date)
                        .offset(x: min(hover.viewPoint.x + 16, geometry.size.width - 240),
                                y: min(hover.viewPoint.y + 16, geometry.size.height - 120))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard model.unfold >= 1 else { return model.hover = nil }
                    model.hover(at: view.toMap(Vec2(location.x, location.y)), viewPoint: location)
                case .ended:
                    model.hover = nil
                }
            }
            .onTapGesture(count: 2) { location in
                var v = view
                v.zoom(by: 2, around: Vec2(location.x, location.y))
                withAnimation(.easeOut(duration: 0.2)) { viewport = v }
            }
            .onTapGesture { location in
                guard let map = model.map, let hit = map.region(atMapPoint: view.toMap(Vec2(location.x, location.y)))
                else { return model.selectedGroup = nil }
                let g = map.grouping.groupOfRegion[hit.region.id]
                model.selectedGroup = model.selectedGroup == g ? nil : g
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragStart == nil { dragStart = view.center }
                        var v = view
                        v.center = dragStart!
                        v.pan(by: Vec2(value.translation.width, value.translation.height))
                        viewport = v
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchStart == nil { pinchStart = (view.zoom, view.center) }
                        var v = view
                        v.zoom = pinchStart!.zoom
                        v.center = pinchStart!.center
                        v.zoom(by: value.magnification, around: Vec2(value.startLocation.x, value.startLocation.y))
                        viewport = v
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            .background {
                CommandScrollReader { steps, location in
                    // Read the viewport afresh: scroll events can arrive
                    // faster than the view updates.
                    var v = currentViewport(size: size)
                    v.zoom(by: pow(2, steps), around: Vec2(location.x, location.y))
                    viewport = v
                }
            }
            .overlay(alignment: .bottomLeading) {
                FoldControl(model: model).padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                ZoomControls(
                    zoomIn: { zoom(view, by: 1.6) },
                    zoomOut: { zoom(view, by: 1 / 1.6) },
                    reset: { withAnimation(.easeOut(duration: 0.25)) { viewport = nil } })
                    .padding(12)
            }
            .onChange(of: model.map?.mesh.faceCount) { viewport = nil }
            .onChange(of: model.selectedGroup) { focusSelection(view) }
        }
    }

    private func currentViewport(size: Vec2) -> Viewport {
        let bounds = model.map?.projection.bounds ?? Rect2(minX: -3.2, minY: -1.6, maxX: 3.2, maxY: 1.6)
        var v = viewport ?? Viewport(bounds: bounds, size: size)
        v.bounds = bounds
        v.size = size
        return v
    }

    private func zoom(_ view: Viewport, by factor: Double) {
        var v = view
        v.zoom(by: factor, around: Vec2(view.size.x / 2, view.size.y / 2))
        withAnimation(.easeOut(duration: 0.2)) { viewport = v }
    }

    /// Brings a group selected from the sidebar into view.
    private func focusSelection(_ view: Viewport) {
        guard let g = model.selectedGroup, let map = model.map,
              let label = map.labels.first(where: { $0.group == g }) else { return }
        let q = view.toView(label.position)
        guard q.x < 0 || q.y < 0 || q.x > view.size.x || q.y > view.size.y else { return }
        var v = view
        v.center = label.position
        withAnimation(.easeOut(duration: 0.3)) { viewport = v }
    }
}

struct HoverCard: View {
    let info: HoverInfo
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.region.clockTime(at: date, seconds: true))
                .font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(info.region.placeName).font(.headline)
            Text("\(info.region.identifier) · \(info.region.abbreviation(at: date))")
                .font(.caption).foregroundStyle(.secondary)
            Text(info.region.offsetLabel(at: date) + (info.region.isDaylightSavingTime(at: date) ? " · daylight saving" : ""))
                .font(.caption).foregroundStyle(.secondary)
            Text(info.location.description).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

struct ZoomControls: View {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (or ⌘-scroll)")
            Button(action: reset) { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Show the whole map")
            Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (or ⌘-scroll)")
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.regularMaterial, in: Capsule())
    }
}

/// Folds the map back into the globe it came from.
struct FoldControl: View {
    @Bindable var model: MapModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.playFold()
            } label: {
                Image(systemName: model.unfold >= 1 ? "globe" : "map")
            }
            .buttonStyle(.borderless)
            .help(model.unfold >= 1 ? "Fold the map into a globe" : "Unfold the globe into the map")
            .disabled(model.isPlayingFold)
            Slider(value: $model.unfold, in: 0...1)
                .frame(width: 140)
                .help("Fold: globe on the left, flat map on the right")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

/// Reports scrolling over the view while ⌘ is held, and keeps it from
/// scrolling anything else. Other scrolling and all clicks pass through.
struct CommandScrollReader: NSViewRepresentable {
    /// Zoom steps (positive: in, one step doubles) and the pointer
    /// position, top-left origin.
    var onScroll: (_ steps: Double, _ location: CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollMonitorView { ScrollMonitorView() }

    func updateNSView(_ view: ScrollMonitorView, context: Context) { view.onScroll = onScroll }

    final class ScrollMonitorView: NSView {
        var onScroll: ((Double, CGPoint) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window, event.modifierFlags.contains(.command),
                      event.window == nil || event.window === window
                else { return event }
                // Events posted straight to the app (automation, remote
                // control) carry no window and a screen position.
                let inWindow = event.window == nil
                    ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
                let p = convert(inWindow, from: nil)
                guard bounds.contains(p) else { return event }
                // Rolling the wheel or swiping away from you zooms in, whatever
                // the scroll direction setting. A wheel notch is a line, a
                // trackpad reports points.
                let away = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
                let steps = away / (event.hasPreciseScrollingDeltas ? 100 : 4)
                onScroll?(steps, CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y))
                return nil
            }
        }
    }
}
