import Foundation
import MyriaGeometry
import ZoneAtlas

/// A styled path in map coordinates. Line widths are in output units
/// (pixels/points), independent of the map scale.
public struct ScenePath: Sendable {
    public enum Role: String, Sendable, Hashable {
        case zone, land, night, coastline, border, cut, mesh, highlight, marked
    }

    public var role: Role
    public var subpaths: [[Vec2]]
    public var closed: Bool
    public var fill: RGBA?
    public var stroke: RGBA?
    public var lineWidth: Double
    /// Zone group the path belongs to, for zone fills and highlights.
    public var group: Int?
}

/// A text label in map coordinates; `size` is the font size in map units.
public struct SceneText: Sendable {
    public enum Weight: Sendable, Hashable { case regular, bold }

    public var position: Vec2
    public var text: String
    public var size: Double
    public var color: RGBA
    public var weight: Weight
}

/// A complete map drawing, independent of any rendering backend.
public struct MapScene: Sendable {
    public var bounds: Rect2
    public var background: RGBA
    public var paths: [ScenePath]
    public var texts: [SceneText]
}

public struct SceneOptions: Sendable, Hashable {
    public var date: Date
    public var style: MapStyle
    public var showLand = true
    public var showCoastlines = true
    public var showBorders = true
    public var showNight = true
    public var showLabels = true
    public var showCuts = false
    public var showMesh = false
    /// Hide the hairline slits inside zones.
    public var sealSlits = true
    public var highlightGroup: Int?
    /// Faces drawn in a warning colour (diagnostics, e.g. overlaps).
    public var markedFaces: [Int] = []
    /// Smallest label room (map units) that still gets a clock.
    public var minimumLabelRoom = 0.035

    public init(date: Date = Date(), style: MapStyle = .light) {
        self.date = date
        self.style = style
    }
}

extension MyriaMap {
    /// Graph colouring of the zone groups: adjacent groups (on the globe) get
    /// different slots, using as few slots as the greedy order allows.
    public func groupColorSlots(slotCount: Int) -> [Int] {
        var neighbors = Array(repeating: Set<Int>(), count: grouping.groups.count)
        for edge in mesh.topology.edges {
            let a = faceGroups[edge.leftFace], b = faceGroups[edge.rightFace]
            if a >= 0, b >= 0, a != b {
                neighbors[a].insert(b)
                neighbors[b].insert(a)
            }
        }
        // DSatur: colour the most constrained group next.
        var slots = Array(repeating: -1, count: neighbors.count)
        var remaining = Set(neighbors.indices)
        while !remaining.isEmpty {
            let next = remaining.max { a, b in
                let sa = Set(neighbors[a].map { slots[$0] }.filter { $0 >= 0 }).count
                let sb = Set(neighbors[b].map { slots[$0] }.filter { $0 >= 0 }).count
                return sa != sb ? sa < sb : (neighbors[a].count != neighbors[b].count
                    ? neighbors[a].count < neighbors[b].count : a > b)
            }!
            remaining.remove(next)
            let used = Set(neighbors[next].map { slots[$0] })
            slots[next] = (0..<slotCount).first { !used.contains($0) } ?? next % slotCount
        }
        return slots
    }

    /// Builds the drawing for a moment in time.
    public func scene(_ options: SceneOptions) -> MapScene {
        let style = options.style
        let transforms = projection.unfolding.transforms
        func mapped(_ ring: [Vec2], _ f: Int) -> [Vec2] { ring.map(transforms[f].apply) }

        var paths: [ScenePath] = []
        let slots = groupColorSlots(slotCount: 5)

        // Zone fills, one path per group.
        var zoneRings = Array(repeating: [[Vec2]](), count: grouping.groups.count)
        for f in 0..<mesh.faceCount {
            for fill in overlay.zoneFills[f] {
                let g = grouping.groupOfRegion[fill.region]
                zoneRings[g].append(contentsOf: fill.rings.map { mapped($0, f) })
            }
        }
        for (g, rings) in zoneRings.enumerated() where !rings.isEmpty {
            // A hairline stroke in the fill colour seals the slits that open
            // between rows inside a zone.
            let color = style.zoneColor(slot: slots[g])
            paths.append(ScenePath(role: .zone, subpaths: rings, closed: true,
                                   fill: color, stroke: options.sealSlits ? color : nil, lineWidth: 0.7, group: g))
        }

        if options.showLand {
            var rings: [[Vec2]] = []
            for f in 0..<mesh.faceCount { rings += overlay.landFills[f].map { mapped($0, f) } }
            paths.append(ScenePath(role: .land, subpaths: rings, closed: true, fill: style.land, stroke: nil, lineWidth: 0))
        }

        if options.showNight {
            paths += nightLayers(date: options.date, style: style)
        }

        if options.showCoastlines {
            var lines: [[Vec2]] = []
            for f in 0..<mesh.faceCount { lines += overlay.coastLines[f].map { mapped($0, f) } }
            paths.append(ScenePath(role: .coastline, subpaths: lines, closed: false, fill: nil,
                                   stroke: style.coastline, lineWidth: 0.5))
        }

        if options.showBorders {
            var lines: [[Vec2]] = []
            for f in 0..<mesh.faceCount { lines += overlay.borderLines[f].map { mapped($0, f) } }
            paths.append(ScenePath(role: .border, subpaths: lines, closed: false, fill: nil,
                                   stroke: style.border, lineWidth: 0.9))
        }

        if options.showMesh {
            let lines = (0..<mesh.faceCount).map { projection.mapPolygons[$0] }
            paths.append(ScenePath(role: .mesh, subpaths: lines, closed: true, fill: nil, stroke: style.mesh, lineWidth: 0.3))
        }

        if options.showCuts {
            var lines: [[Vec2]] = []
            for e in projection.cutEdges {
                for (a, b) in projection.mapSegments(ofEdge: e) { lines.append([a, b]) }
            }
            paths.append(ScenePath(role: .cut, subpaths: lines, closed: false, fill: nil, stroke: style.cut, lineWidth: 0.6))
        }

        if let g = options.highlightGroup, g >= 0, g < zoneRings.count {
            paths.append(ScenePath(role: .highlight, subpaths: outline(ofGroup: g), closed: false, fill: nil,
                                   stroke: style.highlight, lineWidth: 1.6, group: g))
        }

        if !options.markedFaces.isEmpty {
            paths.append(ScenePath(role: .marked, subpaths: options.markedFaces.map { projection.mapPolygons[$0] },
                                   closed: true, fill: RGBA(hex: "#d03b3b", alpha: 0.75), stroke: nil, lineWidth: 0))
        }

        var texts: [SceneText] = []
        if options.showLabels {
            texts = labelTexts(options)
        }
        return MapScene(bounds: projection.bounds, background: style.page, paths: paths, texts: texts)
    }

    /// Map segments bounding a group: cut edges and edges to other groups.
    public func outline(ofGroup g: Int) -> [[Vec2]] {
        var lines: [[Vec2]] = []
        for (e, edge) in mesh.topology.edges.enumerated() {
            let inLeft = faceGroups[edge.leftFace] == g, inRight = faceGroups[edge.rightFace] == g
            guard inLeft || inRight else { continue }
            let segments = projection.mapSegments(ofEdge: e)
            if inLeft && inRight {
                if projection.unfolding.isCut[e] { lines += segments.map { [$0.0, $0.1] } }
            } else {
                let s = inLeft ? segments[0] : segments[1]
                lines.append([s.0, s.1])
            }
        }
        return lines
    }

    /// Day/night shading: the night side, then civil, nautical and
    /// astronomical darkness stacked on top of each other.
    public func nightLayers(date: Date, style: MapStyle) -> [ScenePath] {
        let sun = SolarPosition.sunDirection(at: date)
        return [0.0, 6, 12, 18].map { depression in
            let threshold = -sin(depression * .pi / 180)
            var rings: [[Vec2]] = []
            for f in 0..<mesh.faceCount {
                let frame = mesh.frames[f]
                let local = frame.localVertices
                let values = local.map { threshold - frame.spherePoint($0).dot(sun) }
                if values.allSatisfy({ $0 < 0 }) { continue }
                let dark = values.allSatisfy { $0 >= 0 } ? local : Planar.clip(local, values: values)
                if dark.count >= 3 { rings.append(dark.map(projection.unfolding.transforms[f].apply)) }
            }
            return ScenePath(role: .night, subpaths: rings, closed: true, fill: style.night, stroke: nil, lineWidth: 0)
        }
    }

    /// Clock labels: time, place and UTC offset for every labelled piece.
    public func labelTexts(_ options: SceneOptions) -> [SceneText] {
        let style = options.style
        var texts: [SceneText] = []
        for label in labels where label.room >= options.minimumLabelRoom {
            let region = atlas.regions[label.region]
            let size = min(max(label.room * 0.5, 0.022), 0.07)
            texts.append(SceneText(position: label.position + Vec2(0, size * 0.15), text: region.clockTime(at: options.date),
                                   size: size, color: style.primaryInk, weight: .bold))
            if label.room >= options.minimumLabelRoom * 1.4 {
                let small = size * 0.42
                texts.append(SceneText(position: label.position - Vec2(0, size * 0.62), text: region.placeName,
                                       size: small, color: style.secondaryInk, weight: .regular))
                texts.append(SceneText(position: label.position - Vec2(0, size * 0.62 + small * 1.15),
                                       text: region.offsetLabel(at: options.date),
                                       size: small * 0.9, color: style.mutedInk, weight: .regular))
            }
        }
        return texts
    }
}
