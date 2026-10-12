import MyriaGeometry
import Myriamap
import SwiftUI
import ZoneAtlas

/// The unfolded map: static layers, day/night, live clocks, hover and
/// selection, with pinch/drag/double-click navigation.
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
                Canvas(opaque: true, rendersAsynchronously: true) { context, _ in
                    context.fill(Path(CGRect(origin: .zero, size: geometry.size)), with: .color(Color(model.style.page)))
                    var mapContext = context
                    mapContext.concatenate(transform(view))
                    if model.unfold < 1 {
                        draw(model.foldedLayers, in: &mapContext, scale: view.scale)
                        return
                    }
                    draw(model.staticLayers, in: &mapContext, scale: view.scale)
                    draw(model.nightLayers, in: &mapContext, scale: view.scale)
                    if let map = model.map {
                        for g in Set([model.selectedGroup, model.hover?.group].compactMap { $0 }) {
                            let outline = Path { p in
                                for line in map.outline(ofGroup: g) { p.addLines(line.map { CGPoint(x: $0.x, y: $0.y) }) }
                            }
                            mapContext.stroke(outline, with: .color(Color(model.style.highlight)),
                                              style: StrokeStyle(lineWidth: (g == model.selectedGroup ? 2 : 1.2) / view.scale,
                                                                 lineCap: .round, lineJoin: .round))
                        }
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Canvas { context, _ in
                        guard model.unfold >= 1 else { return }
                        for label in model.labels() {
                            let q = view.toView(label.position)
                            let size = label.size * view.scale
                            guard size >= 7 else { continue }
                            let text = Text(label.text)
                                .font(.system(size: size, weight: label.weight == .bold ? .semibold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(Color(label.color))
                            context.draw(text, at: CGPoint(x: q.x, y: q.y), anchor: .center)
                        }
                    }
                    .allowsHitTesting(false)
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

    private func transform(_ v: Viewport) -> CGAffineTransform {
        CGAffineTransform(a: v.scale, b: 0, c: 0, d: -v.scale,
                          tx: v.size.x / 2 - v.center.x * v.scale, ty: v.size.y / 2 + v.center.y * v.scale)
    }

    private func draw(_ layers: [LayerPath], in context: inout GraphicsContext, scale: Double) {
        for layer in layers {
            if let fill = layer.fill {
                context.fill(layer.path, with: .color(fill), style: FillStyle(eoFill: false, antialiased: true))
            }
            if let stroke = layer.stroke {
                context.stroke(layer.path, with: .color(stroke),
                               style: StrokeStyle(lineWidth: layer.lineWidth / scale, lineCap: .round, lineJoin: .round))
            }
        }
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
                .help("Zoom out")
            Button(action: reset) { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Show the whole map")
            Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
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
