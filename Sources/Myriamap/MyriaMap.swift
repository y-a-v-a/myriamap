import Foundation
import MyriaGeometry
import ZoneAtlas

/// The polyhedron that approximates the globe.
public enum MeshKind: Hashable, Sendable, Codable {
    /// Subdivided icosahedron with `20 · frequency²` triangles.
    case geodesic(frequency: Int)
    /// Latitude/longitude cells of `step` degrees; steps dividing 7.5° align
    /// with the nautical timezone meridians.
    case graticule(step: Double)

    public func polyhedron() -> Polyhedron {
        switch self {
        case .geodesic(let n): .geodesic(frequency: n)
        case .graticule(let step): .graticule(latitudeStep: step, longitudeStep: step)
        }
    }

    public var title: String {
        switch self {
        case .geodesic(let n): "Geodesic, \(20 * n * n) triangles"
        case .graticule(let s): "Graticule, \(String(format: "%g", s))° cells"
        }
    }

    /// Parses "geodesic:32" or "graticule:1.875".
    public init?(argument: String) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "geodesic": guard let n = Int(parts[1]), n > 0 else { return nil }; self = .geodesic(frequency: n)
        case "graticule": guard let s = Double(parts[1]), s > 0, s <= 45 else { return nil }; self = .graticule(step: s)
        default: return nil
        }
    }

    public var argument: String {
        switch self {
        case .geodesic(let n): "geodesic:\(n)"
        case .graticule(let s): "graticule:\(String(format: "%g", s))"
        }
    }
}

/// Bundled geographic data.
public struct GeoData: Sendable {
    public let atlas: ZoneAtlas
    public let land: LandMask

    public init(atlas: ZoneAtlas, land: LandMask) {
        self.atlas = atlas
        self.land = land
    }

    public static func bundled() throws -> GeoData {
        GeoData(atlas: try .bundled(), land: try .bundled())
    }
}

/// A mesh together with its geographic overlay: everything that depends only
/// on the polyhedron and not on where it is cut.
public struct MeshOverlay: Sendable {
    public let kind: MeshKind
    public let mesh: MyriahedralMesh
    public let overlay: FaceOverlay

    public init(kind: MeshKind, data: GeoData) throws {
        self.kind = kind
        mesh = try MyriahedralMesh(kind.polyhedron())
        overlay = FaceOverlay(mesh: mesh, atlas: data.atlas, land: data.land)
    }
}

/// How the map is cut and laid out.
public struct MapConfiguration: Hashable, Sendable {
    public enum Cuts: String, Hashable, Sendable, CaseIterable {
        /// Seams follow timezone borders (the point of this app).
        case timezones
        /// Seams run through the oceans (van Wijk's classic).
        case landmass
    }

    public var mesh: MeshKind
    public var cuts: Cuts
    public var grouping: CutGrouping
    public var centerLongitude: Double
    public var equatorBias: Double
    /// Date whose UTC offsets define `.utcOffset` grouping.
    public var referenceDate: Date

    public init(mesh: MeshKind = .graticule(step: 1.875), cuts: Cuts = .timezones, grouping: CutGrouping = .region,
                centerLongitude: Double = 10, equatorBias: Double = 2, referenceDate: Date = Date()) {
        self.mesh = mesh
        self.cuts = cuts
        self.grouping = grouping
        self.centerLongitude = centerLongitude
        self.equatorBias = equatorBias
        self.referenceDate = referenceDate
    }
}

/// Where the clock for one zone piece is drawn.
public struct GroupLabel: Sendable, Hashable {
    public let group: Int
    /// Region whose name and clock are shown.
    public let region: Int
    public let position: Vec2
    /// Rough radius of free space around the label, in map units.
    public let room: Double
    /// Area of the labelled piece on the globe (steradians).
    public let area: Double
}

/// The timezone myriahedral map: a mesh cut along timezone borders and
/// unfolded flat.
public struct MyriaMap: Sendable {
    public let base: MeshOverlay
    public let data: GeoData
    public let configuration: MapConfiguration
    public let grouping: ZoneGrouping
    /// Zone group per face, or -1.
    public let faceGroups: [Int]
    public let projection: MyriahedralProjection
    public let labels: [GroupLabel]
    /// Colour slot per zone group, neighbours apart (see `groupColorSlots`).
    public let colorSlots: [Int]

    public var mesh: MyriahedralMesh { base.mesh }
    public var overlay: FaceOverlay { base.overlay }
    public var atlas: ZoneAtlas { data.atlas }

    public init(base: MeshOverlay, data: GeoData, configuration: MapConfiguration) {
        self.base = base
        self.data = data
        self.configuration = configuration
        let grouping = ZoneGrouping(atlas: data.atlas, grouping: configuration.grouping, date: configuration.referenceDate)
        self.grouping = grouping
        let mesh = base.mesh, overlay = base.overlay

        let faceGroups: [Int] = (0..<mesh.faceCount).map { f in
            var area: [Int: Double] = [:]
            for fill in overlay.zoneFills[f] { area[grouping.groupOfRegion[fill.region], default: 0] += fill.area }
            return area.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? -1
        }
        self.faceGroups = faceGroups

        let root = mesh.face(containing: GeoPoint(latitude: 0, longitude: configuration.centerLongitude).unitVector)
        let hinges: [Bool]
        switch configuration.cuts {
        case .timezones:
            let strategy = TimeZoneCutStrategy(centerLongitude: configuration.centerLongitude,
                                               equatorBias: configuration.equatorBias)
            let cutGroups = Self.splittingPolarCaps(faceGroups, mesh: mesh, groupCount: grouping.groups.count)
            hinges = strategy.hinges(mesh: mesh, faceGroups: cutGroups, root: root)
        case .landmass:
            let landFaces = (0..<mesh.faceCount).map { f in
                overlay.landFills[f].reduce(0) { $0 + Planar.signedArea($1) } > mesh.frames[f].area / 2 ? 1 : 0
            }
            hinges = LandmassCutStrategy(centerLongitude: configuration.centerLongitude)
                .hinges(mesh: mesh, faceGroups: landFaces, root: root)
        }
        projection = MyriahedralProjection(mesh: mesh, hinges: hinges, root: root)
        labels = Self.placeLabels(mesh: mesh, overlay: overlay, grouping: grouping, faceGroups: faceGroups,
                                  projection: projection)
        colorSlots = Self.groupColorSlots(mesh: mesh, faceGroups: faceGroups, groupCount: grouping.groups.count,
                                          slotCount: MapStyle.slotCount)
    }

    /// Convenience: builds the mesh overlay and the map in one go.
    public init(data: GeoData, configuration: MapConfiguration) throws {
        self.init(base: try MeshOverlay(kind: configuration.mesh, data: data), data: data, configuration: configuration)
    }

    /// Region at a map position (exact polygon lookup), with its globe location.
    public func region(atMapPoint q: Vec2) -> (region: TimeZoneRegion, location: GeoPoint, face: Int)? {
        guard let (face, location) = projection.inverse(q), let region = atlas.region(at: location) else { return nil }
        return (region, location, face)
    }

    /// A region that wraps around a pole (Antarctica keeps New Zealand time)
    /// cannot unfold in one piece without heavy distortion. For cutting
    /// only, its polar faces are split into the 15° nautical sectors, so each
    /// sector hangs off the gore next to it.
    static func splittingPolarCaps(_ faceGroups: [Int], mesh: MyriahedralMesh, groupCount: Int,
                                   latitude: Double = 60, maxSectors: Int = 6) -> [Int] {
        let centers = (0..<mesh.faceCount).map { GeoPoint(mesh.polyhedron.faceCenter($0)) }
        func sector(_ p: GeoPoint) -> Int {
            ((Int(((p.longitude + 7.5) / 15).rounded(.down)) % 24) + 24) % 24
        }
        var sectors: [Int: Set<Int>] = [:]
        for f in 0..<mesh.faceCount where faceGroups[f] >= 0 && abs(centers[f].latitude) > latitude {
            let pole = centers[f].latitude > 0 ? 1 : 0
            sectors[faceGroups[f] * 2 + pole, default: []].insert(sector(centers[f]))
        }
        return (0..<mesh.faceCount).map { f in
            let g = faceGroups[f], p = centers[f]
            guard g >= 0, abs(p.latitude) > latitude else { return g }
            let pole = p.latitude > 0 ? 1 : 0
            guard (sectors[g * 2 + pole]?.count ?? 0) > maxSectors else { return g }
            return groupCount + (g * 2 + pole) * 24 + sector(p)
        }
    }

    /// Connected pieces of each group: faces joined by hinges inside the group.
    public func pieces() -> [[Int]] {
        Self.pieces(mesh: mesh, faceGroups: faceGroups, projection: projection)
    }

    static func pieces(mesh: MyriahedralMesh, faceGroups: [Int], projection: MyriahedralProjection) -> [[Int]] {
        var sets = UnionFind(count: mesh.faceCount)
        for (e, edge) in mesh.topology.edges.enumerated()
        where !projection.unfolding.isCut[e] && faceGroups[edge.leftFace] == faceGroups[edge.rightFace] {
            sets.union(edge.leftFace, edge.rightFace)
        }
        var byRoot: [Int: [Int]] = [:]
        for f in 0..<mesh.faceCount { byRoot[sets.find(f), default: []].append(f) }
        return Array(byRoot.values)
    }

    static func placeLabels(mesh: MyriahedralMesh, overlay: FaceOverlay, grouping: ZoneGrouping, faceGroups: [Int],
                            projection: MyriahedralProjection) -> [GroupLabel] {
        let faceArea = mesh.frames.map(\.area)
        // Prefer big pieces at moderate latitudes: Auckland's clock belongs on
        // New Zealand rather than on the Antarctic sectors that share its time.
        let faceWeight = (0..<mesh.faceCount).map { f in
            faceArea[f] * (1 - pow(mesh.polyhedron.faceCenter(f).z, 2))
        }
        var best: [Int: (faces: [Int], area: Double, weight: Double)] = [:]
        for piece in pieces(mesh: mesh, faceGroups: faceGroups, projection: projection) {
            let g = faceGroups[piece[0]]
            guard g >= 0 else { continue }
            let weight = piece.reduce(0) { $0 + faceWeight[$1] }
            if weight > best[g]?.weight ?? 0 { best[g] = (piece, piece.reduce(0) { $0 + faceArea[$1] }, weight) }
        }
        let typicalEdge = (4 * Double.pi / Double(mesh.faceCount)).squareRoot()
        return best.keys.sorted().compactMap { g -> GroupLabel? in
            guard let (faces, area, _) = best[g] else { return nil }
            let members = Set(faces)
            // Hops to the zone border within the piece (slits don't count).
            var depth: [Int: Int] = [:]
            var queue: [Int] = []
            for f in faces where mesh.topology.neighbors(of: f).contains(where: { !members.contains($0) }) {
                depth[f] = 0
                queue.append(f)
            }
            var head = 0
            while head < queue.count {
                let f = queue[head]
                head += 1
                for h in mesh.topology.neighbors(of: f) where members.contains(h) && depth[h] == nil {
                    depth[h] = depth[f]! + 1
                    queue.append(h)
                }
            }
            // Deepest face; among equals the one nearest the equator, so the
            // clocks of the gores line up along the belt.
            let latitude = { (f: Int) in abs(mesh.polyhedron.faceCenter(f).z) }
            guard let (center, d) = depth.max(by: { a, b in
                a.value != b.value ? a.value < b.value
                    : (latitude(a.key) != latitude(b.key) ? latitude(a.key) > latitude(b.key) : a.key > b.key)
            }) else { return nil }
            var regionArea: [Int: Double] = [:]
            for f in faces {
                for fill in overlay.zoneFills[f] where grouping.groupOfRegion[fill.region] == g {
                    regionArea[fill.region, default: 0] += fill.area
                }
            }
            // Name the region under the label; when a group spans several
            // regions (offset grouping) that keeps the name and place together.
            let under = overlay.dominantRegion(of: center)
            let region = under >= 0 && grouping.groupOfRegion[under] == g
                ? under : (regionArea.max { $0.value < $1.value }?.key ?? grouping.groups[g].primaryRegion)
            let position = Planar.centroid(projection.mapPolygons[center])
            return GroupLabel(group: g, region: region, position: position,
                              room: (Double(d) + 0.5) * typicalEdge, area: area)
        }
    }
}
