import SwiftUI

extension View {
    /// The inspector. Since macOS 26 the sidebar floats over the window as a
    /// pane of glass while the system's inspector sits edge to edge, taking
    /// the toolbar with it; here it floats as the sidebar does, on the other
    /// side. Before macOS 26 it is the system's inspector column.
    func floatingInspector<Panel: View>(isPresented: Binding<Bool>, @ViewBuilder content: () -> Panel) -> some View {
        modifier(FloatingInspector(isPresented: isPresented, panel: content()))
    }
}

struct FloatingInspector<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let panel: Panel
    @AppStorage("inspectorWidth") private var savedWidth = 290.0
    /// How far the pane's edge has been dragged in a resize.
    @GestureState private var resize = 0.0

    static var widths: ClosedRange<Double> { 260...380 }
    /// How far the pane keeps from the window's edges, as the sidebar does.
    static var margin: CGFloat { 8 }

    private var width: Double { (savedWidth - resize).clamped(to: Self.widths) }

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.modifier(SlidingPane(shown: isPresented ? 1 : 0, room: width + Self.margin, pane: pane))
        } else {
            content.inspector(isPresented: $isPresented) {
                panel.inspectorColumnWidth(min: Self.widths.lowerBound, ideal: 290, max: Self.widths.upperBound)
            }
        }
    }

    @available(macOS 26, *)
    private var pane: some View {
        // Up under the toolbar, as high as the sidebar goes; what scrolls
        // past either end stays within the glass.
        let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true)
        return panel
            .scrollContentBackground(.hidden)
            .frame(width: width)
            .mask {
                shape.padding(.top, Self.margin).ignoresSafeArea(.container, edges: .top)
            }
            .background {
                Color.clear
                    .glassEffect(.regular, in: shape)
                    .padding(.top, Self.margin)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .overlay(alignment: .leading) { resizeHandle }
            .padding([.trailing, .bottom], Self.margin)
    }

    /// The pane's leading edge, dragged to make it wider or narrower.
    @available(macOS 26, *)
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: -4)
            .pointerStyle(.frameResize(position: .leading))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($resize) { drag, resize, _ in resize = drag.translation.width }
                    .onEnded { drag in
                        savedWidth = (savedWidth.clamped(to: Self.widths) - drag.translation.width).clamped(to: Self.widths)
                    }
            )
    }
}

/// Keeps the map to the room left of the pane. The room is laid out afresh
/// at every step of the pane's coming and going, as the sidebar's is: an
/// inserted view would give the map its final size at once and leave it to
/// jump beneath the moving pane.
private struct SlidingPane<Pane: View>: ViewModifier, Animatable {
    /// How far the pane is in: 0 out of sight, 1 all the way.
    nonisolated var shown: Double
    /// The pane's width with its margin.
    let room: Double
    let pane: Pane

    nonisolated var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .trailing, spacing: 0) {
            if shown > 0 {
                Color.clear
                    .frame(width: room * shown)
                    .overlay(alignment: .leading) { pane.opacity(shown) }
            }
        }
    }
}

/// A section title, small, as the system's inspector sets it. Outside a
/// system inspector, as in the floating one of macOS 26, a form sets its
/// titles large and its sections apart as Settings does.
struct InspectorHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        if #available(macOS 26, *) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, -14)  // No section spacing API on macOS.
        } else {
            Text(title)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
