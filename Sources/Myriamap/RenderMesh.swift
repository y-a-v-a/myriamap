import Foundation
import MyriaGeometry

/// A vertex of a filled triangle in its face's local coordinates. The
/// layout matches the Metal shaders.
public struct FillVertex: Sendable, Hashable {
    public var x: Float
    public var y: Float
    public var face: UInt32
    /// Timezone region of a zone fill; 0 for land.
    public var region: UInt32
}

/// A line segment in its face's local coordinates, or in map coordinates
/// when `face` is the mesh's face count. The layout matches the Metal
/// shaders.
public struct LineSegment: Sendable, Hashable {
    public var ax: Float
    public var ay: Float
    public var bx: Float
    public var by: Float
    public var face: UInt32
    /// Timezone region of a zone outline; 0 for other lines.
    public var region: UInt32

    public init(_ a: Vec2, _ b: Vec2, face: Int, region: Int = 0) {
        (ax, ay, bx, by) = (Float(a.x), Float(a.y), Float(b.x), Float(b.y))
        self.face = UInt32(face)
        self.region = UInt32(region)
    }
}

/// Face-local → view coordinates as the rows of a 3×4 matrix: a face-local
/// point (x, y) lands at `rows · (x, y, 0, 1)`; the z column holds the face
/// normal, so `z.z < 0` means the face is turned away from the viewer.
public struct FaceTransform: Sendable, Hashable {
    public var x: SIMD4<Float>
    public var y: SIMD4<Float>
    public var z: SIMD4<Float>

    public init(_ pose: Pose3) {
        let r = pose.rotation, t = pose.translation
        x = SIMD4(Float(r.c0.x), Float(r.c1.x), Float(r.c2.x), Float(t.x))
        y = SIMD4(Float(r.c0.y), Float(r.c1.y), Float(r.c2.y), Float(t.y))
        z = SIMD4(Float(r.c0.z), Float(r.c1.z), Float(r.c2.z), Float(t.z))
    }

    public init(_ motion: Rigid2D) {
        let (c, s, t) = (Float(motion.cosine), Float(motion.sine), motion.translation)
        x = SIMD4(c, -s, 0, Float(t.x))
        y = SIMD4(s, c, 0, Float(t.y))
        z = SIMD4(0, 0, 1, 0)
    }

    public static let identity = FaceTransform(Rigid2D.identity)
}

/// A face's plane on the globe: the point at local (x, y) is
/// `origin + x · xAxis + y · yAxis`, which normalised is the location it shows.
public struct FacePlane: Sendable, Hashable {
    public var origin: SIMD4<Float>
    public var xAxis: SIMD4<Float>
    public var yAxis: SIMD4<Float>

    init(_ frame: FaceFrame) {
        func v(_ p: Vec3) -> SIMD4<Float> { SIMD4(Float(p.x), Float(p.y), Float(p.z), 0) }
        origin = v(frame.origin)
        xAxis = v(frame.xAxis)
        yAxis = v(frame.yAxis)
    }
}

/// Where each face's part of a list starts and ends.
public struct FaceRanges: Sendable {
    /// Face count + 1 offsets.
    let starts: [Int]

    init(counts: [Int]) {
        var starts = [0]
        starts.reserveCapacity(counts.count + 1)
        for c in counts { starts.append(starts[starts.count - 1] + c) }
        self.starts = starts
    }

    public func range(of face: Int) -> Range<Int> { starts[face]..<starts[face + 1] }
}

/// The geometry of a mesh overlay ready for the GPU. Everything is in face-
/// local coordinates, so the same buffers draw any cuts at any stage of
/// folding; only the per-face transforms change. Every list keeps its
/// faces in order, so a face's part can be found and moved as a block.
public struct RenderMesh: Sendable {
    public let faceCount: Int
    /// Zone fills: corners tagged with their region, and triangles indexing
    /// them. Neighbouring triangles share corners, so each is shaded once.
    public let zoneVertices: [FillVertex]
    public let zoneIndices: [UInt32]
    public let landVertices: [FillVertex]
    public let landIndices: [UInt32]
    /// Every face's polygon as a fan, tagged with the region covering most
    /// of it.
    public let faceVertices: [FillVertex]
    public let faceIndices: [UInt32]
    /// The rings of the zone fills, tagged with their region: drawn as
    /// hairlines in the fill colour they seal the slits that open between
    /// rows inside a zone.
    public let zoneOutlines: [LineSegment]
    /// Per zone outline segment, the mesh edge it runs along, or -1 inside
    /// a face.
    public let zoneOutlineEdges: [Int32]
    public let coastlines: [LineSegment]
    public let borders: [LineSegment]
    /// Every face's polygon.
    public let faceEdges: [LineSegment]
    public let planes: [FacePlane]
    /// Each face's part of the index and line lists.
    public let zoneIndexRanges: FaceRanges
    public let landIndexRanges: FaceRanges
    public let faceIndexRanges: FaceRanges
    public let zoneOutlineRanges: FaceRanges
    public let coastlineRanges: FaceRanges
    public let borderRanges: FaceRanges
    public let faceEdgeRanges: FaceRanges

    public init(_ base: MeshOverlay) {
        let mesh = base.mesh, overlay = base.overlay, n = mesh.faceCount
        /// The lengths of a chunk's lists.
        struct Sizes: Sendable {
            let zones, land, faces, outlines, coasts, borders, edges: Int
        }
        /// A run of faces, built on one thread.
        struct Chunk: Sendable {
            var zones = Fill(), land = Fill(), faces = Fill()
            var outlines: [LineSegment] = [], outlineEdges: [Int32] = []
            var coasts: [LineSegment] = [], borders: [LineSegment] = [], edges: [LineSegment] = []
            /// Per face, the lengths of the lists once it was added.
            var ends: [Sizes] = []
        }
        let chunkSize = 64
        let chunks = parallelMap((n + chunkSize - 1) / chunkSize) { c -> Chunk in
            var chunk = Chunk()
            for f in (c * chunkSize)..<min(n, (c + 1) * chunkSize) {
                for fill in overlay.zoneFills[f] {
                    chunk.zones.add(fill.rings, face: f, region: fill.region)
                    let first = chunk.outlines.count
                    Self.segments(rings: fill.rings, face: f, region: fill.region, into: &chunk.outlines)
                    for s in chunk.outlines[first...] { chunk.outlineEdges.append(Self.meshEdge(along: s, face: f, mesh: mesh)) }
                }
                chunk.land.add(overlay.landFills[f], face: f, region: 0)
                Self.segments(lines: overlay.coastLines[f], face: f, into: &chunk.coasts)
                Self.segments(lines: overlay.borderLines[f], face: f, into: &chunk.borders)
                Self.segments(rings: [mesh.frames[f].localVertices], face: f, region: 0, into: &chunk.edges)
                chunk.faces.add([mesh.frames[f].localVertices], face: f, region: max(overlay.dominantRegion(of: f), 0))
                chunk.ends.append(Sizes(zones: chunk.zones.indices.count, land: chunk.land.indices.count,
                                        faces: chunk.faces.indices.count, outlines: chunk.outlines.count,
                                        coasts: chunk.coasts.count, borders: chunk.borders.count, edges: chunk.edges.count))
            }
            return chunk
        }
        func ranges(_ size: (Sizes) -> Int) -> FaceRanges {
            var counts: [Int] = []
            counts.reserveCapacity(n)
            for chunk in chunks {
                var previous = 0
                for end in chunk.ends {
                    counts.append(size(end) - previous)
                    previous = size(end)
                }
            }
            return FaceRanges(counts: counts)
        }
        faceCount = n
        (zoneVertices, zoneIndices) = Fill.joined(chunks.map { $0.zones })
        (landVertices, landIndices) = Fill.joined(chunks.map { $0.land })
        (faceVertices, faceIndices) = Fill.joined(chunks.map { $0.faces })
        zoneOutlines = Self.joined(chunks.map { $0.outlines })
        zoneOutlineEdges = Self.joined(chunks.map { $0.outlineEdges })
        coastlines = Self.joined(chunks.map { $0.coasts })
        borders = Self.joined(chunks.map { $0.borders })
        faceEdges = Self.joined(chunks.map { $0.edges })
        planes = mesh.frames.map(FacePlane.init)
        zoneIndexRanges = ranges { $0.zones }
        landIndexRanges = ranges { $0.land }
        faceIndexRanges = ranges { $0.faces }
        zoneOutlineRanges = ranges { $0.outlines }
        coastlineRanges = ranges { $0.coasts }
        borderRanges = ranges { $0.borders }
        faceEdgeRanges = ranges { $0.edges }
    }

    /// Triangles as shared corners and indices into them.
    struct Fill: Sendable {
        var vertices: [FillVertex] = []
        var indices: [UInt32] = []

        /// Triangulates rings into the fill; corners are shared within one
        /// region's fill.
        mutating func add(_ rings: [[Vec2]], face: Int, region: Int) {
            guard !rings.isEmpty else { return }
            var corners: [Vec2] = []
            let base = UInt32(vertices.count)
            let first = indices.count
            Triangulation.fill(rings, vertices: &corners, indices: &indices)
            for i in first..<indices.count { indices[i] += base }
            for q in corners {
                vertices.append(FillVertex(x: Float(q.x), y: Float(q.y), face: UInt32(face), region: UInt32(region)))
            }
        }

        /// All faces' fills in one list, indices offset to match.
        static func joined(_ fills: [Fill]) -> ([FillVertex], [UInt32]) {
            var vertices: [FillVertex] = [], indices: [UInt32] = []
            vertices.reserveCapacity(fills.reduce(0) { $0 + $1.vertices.count })
            indices.reserveCapacity(fills.reduce(0) { $0 + $1.indices.count })
            for fill in fills {
                let base = UInt32(vertices.count)
                vertices += fill.vertices
                indices += fill.indices.map { $0 + base }
            }
            return (vertices, indices)
        }
    }

    static func segments(rings: [[Vec2]], face: Int, region: Int, into out: inout [LineSegment]) {
        for ring in rings where ring.count >= 2 {
            var a = ring[ring.count - 1]
            for b in ring {
                out.append(LineSegment(a, b, face: face, region: region))
                a = b
            }
        }
    }

    /// The edge of face `f` that a segment in its local coordinates runs
    /// along, as a mesh edge index, or -1.
    static func meshEdge(along s: LineSegment, face f: Int, mesh: MyriahedralMesh) -> Int32 {
        let polygon = mesh.frames[f].localVertices
        let a = Vec2(Double(s.ax), Double(s.ay)), b = Vec2(Double(s.bx), Double(s.by))
        for i in polygon.indices {
            let p = polygon[i], d = polygon[(i + 1) % polygon.count] - p
            // The segment was rounded to Float; allow for that.
            let tolerance = 1e-6 * d.length
            if abs(d.cross(a - p)) <= tolerance * d.length, abs(d.cross(b - p)) <= tolerance * d.length {
                return Int32(mesh.topology.faceEdges[f][i])
            }
        }
        return -1
    }

    static func segments(lines: [[Vec2]], face: Int, into out: inout [LineSegment]) {
        for line in lines where line.count >= 2 {
            for i in 1..<line.count { out.append(LineSegment(line[i - 1], line[i], face: face)) }
        }
    }

    static func joined<T>(_ parts: [[T]]) -> [T] {
        var out: [T] = []
        out.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts { out += part }
        return out
    }
}

/// The flat map divided into a grid of cells, with the geometry regrouped
/// cell by cell: a view of part of the map draws only the cells it shows,
/// as a few runs of consecutive cells.
public struct MapCells: Sendable {
    public struct Cell: Sendable {
        /// Map bounds of the cell's faces.
        public let bounds: Rect2
        let zones: Range<Int>
        let land: Range<Int>
        let faces: Range<Int>
        let seals: Range<Int>
        let coastlines: Range<Int>
        let borders: Range<Int>
        let faceEdges: Range<Int>
    }

    public let cells: [Cell]
    /// Triangles indexing the mesh's zone and land corners.
    public let zoneIndices: [UInt32]
    public let landIndices: [UInt32]
    /// The face polygons that go beneath the fills.
    public let faceIndices: [UInt32]
    /// Zone outlines along cut edges: on the flat map the only places where
    /// faces part, so the only ones that need sealing.
    public let seals: [LineSegment]
    public let coastlines: [LineSegment]
    public let borders: [LineSegment]
    public let faceEdges: [LineSegment]

    /// Each face goes to the cell holding its centre.
    public init(map: MyriaMap, mesh: RenderMesh, columns: Int = 32, rows: Int = 16) {
        let polygons = map.projection.mapPolygons, box = map.projection.bounds
        let isCut = map.projection.unfolding.isCut
        let n = polygons.count, count = columns * rows
        let cellOfFace = polygons.map { polygon -> Int in
            let c = Planar.centroid(polygon)
            let col = min(columns - 1, max(0, Int((c.x - box.minX) / max(box.width, 1e-12) * Double(columns))))
            let row = min(rows - 1, max(0, Int((c.y - box.minY) / max(box.height, 1e-12) * Double(rows))))
            return row * columns + col
        }
        var facesOfCell = Array(repeating: [Int](), count: count)
        for f in 0..<n { facesOfCell[cellOfFace[f]].append(f) }

        var zoneIndices: [UInt32] = [], landIndices: [UInt32] = [], faceIndices: [UInt32] = []
        var seals: [LineSegment] = [], coastlines: [LineSegment] = [], borders: [LineSegment] = []
        var faceEdges: [LineSegment] = []
        zoneIndices.reserveCapacity(mesh.zoneIndices.count)
        landIndices.reserveCapacity(mesh.landIndices.count)
        coastlines.reserveCapacity(mesh.coastlines.count)
        borders.reserveCapacity(mesh.borders.count)
        faceEdges.reserveCapacity(mesh.faceEdges.count)
        var cells: [Cell] = []
        cells.reserveCapacity(count)
        for faces in facesOfCell {
            let start = (zoneIndices.count, landIndices.count, seals.count, coastlines.count, borders.count, faceEdges.count,
                         faceIndices.count)
            var bounds = Rect2.empty
            for f in faces {
                bounds.include(Rect2(bounding: polygons[f]))
                zoneIndices += mesh.zoneIndices[mesh.zoneIndexRanges.range(of: f)]
                landIndices += mesh.landIndices[mesh.landIndexRanges.range(of: f)]
                faceIndices += mesh.faceIndices[mesh.faceIndexRanges.range(of: f)]
                for i in mesh.zoneOutlineRanges.range(of: f) {
                    let e = mesh.zoneOutlineEdges[i]
                    if e >= 0, isCut[Int(e)] { seals.append(mesh.zoneOutlines[i]) }
                }
                coastlines += mesh.coastlines[mesh.coastlineRanges.range(of: f)]
                borders += mesh.borders[mesh.borderRanges.range(of: f)]
                faceEdges += mesh.faceEdges[mesh.faceEdgeRanges.range(of: f)]
            }
            cells.append(Cell(bounds: bounds, zones: start.0..<zoneIndices.count, land: start.1..<landIndices.count,
                              faces: start.6..<faceIndices.count,
                              seals: start.2..<seals.count, coastlines: start.3..<coastlines.count,
                              borders: start.4..<borders.count, faceEdges: start.5..<faceEdges.count))
        }
        self.cells = cells
        self.zoneIndices = zoneIndices
        self.landIndices = landIndices
        self.faceIndices = faceIndices
        self.seals = seals
        self.coastlines = coastlines
        self.borders = borders
        self.faceEdges = faceEdges
    }

    /// The cells whose faces reach into `rect`, as runs of consecutive cells.
    public func runs(overlapping rect: Rect2) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        for (i, cell) in cells.enumerated() {
            // Empty cells cost nothing, so they never break a run.
            let extends = runs.last?.upperBound == i
            if cell.bounds.isEmpty || !cell.bounds.intersects(rect) {
                if cell.bounds.isEmpty, extends { runs[runs.count - 1] = runs[runs.count - 1].lowerBound..<(i + 1) }
            } else if extends {
                runs[runs.count - 1] = runs[runs.count - 1].lowerBound..<(i + 1)
            } else {
                runs.append(i..<(i + 1))
            }
        }
        return runs
    }

    /// Everything, as one run.
    public var all: [Range<Int>] { [0..<cells.count] }

    /// The part of a list that a run of cells covers.
    func span(_ run: Range<Int>, _ part: KeyPath<Cell, Range<Int>>) -> Range<Int> {
        cells[run.lowerBound][keyPath: part].lowerBound..<cells[run.upperBound - 1][keyPath: part].upperBound
    }
}

extension MyriaMap {
    /// Face-local → map transforms of the flat map, followed by the identity
    /// for geometry already in map coordinates.
    public func flatFaceTransforms() -> [FaceTransform] {
        projection.unfolding.transforms.map(FaceTransform.init) + [.identity]
    }

    /// Face-local → view transforms partly folded towards the globe (see
    /// `foldedScene`), followed by the identity.
    public func foldedFaceTransforms(unfold: Double, folding: Folding, tilt: Double = 0.35) -> [FaceTransform] {
        var poses: [Pose3] = []
        var transforms = Array(repeating: FaceTransform.identity, count: mesh.faceCount + 1)
        transforms.withUnsafeMutableBufferPointer {
            writeFoldedFaceTransforms(unfold: unfold, folding: folding, tilt: tilt, poses: &poses, into: $0.baseAddress!)
        }
        return transforms
    }

    /// Writes the folded transforms and the identity into `out`, which has
    /// room for the face count plus one; `poses` is scratch space kept
    /// between frames.
    public func writeFoldedFaceTransforms(unfold: Double, folding: Folding, tilt: Double = 0.35, poses: inout [Pose3],
                                          into out: UnsafeMutablePointer<FaceTransform>) {
        folding.poses(unfold: unfold, camera: FoldCamera(unfold: unfold, tilt: tilt).pose, into: &poses)
        for (f, pose) in poses.enumerated() { out[f] = FaceTransform(pose) }
        out[poses.count] = .identity
    }

    /// The fill colour of every region in a style.
    public func regionColors(style: MapStyle) -> [RGBA] {
        grouping.groupOfRegion.map { g in g >= 0 ? style.zoneColor(slot: colorSlots[g]) : style.surface }
    }

    /// The corners of the mesh's face polygons on the flat map, in the
    /// order of `RenderMesh.faceVertices`.
    public func flatFaceCorners(_ mesh: RenderMesh) -> [SIMD2<Float>] {
        let transforms = projection.unfolding.transforms, corners = mesh.faceVertices
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(corners.count)
        var i = 0
        while i < corners.count {
            let f = Int(corners[i].face)
            var j = i
            while j < corners.count, corners[j].face == corners[i].face { j += 1 }
            // A face's fan keeps its polygon's corners in order: take them
            // from the map polygon, placed in double precision.
            let polygon = projection.mapPolygons[f]
            if j - i == polygon.count {
                out += polygon.map { SIMD2(Float($0.x), Float($0.y)) }
            } else {
                out += corners[i..<j].map { v in
                    let q = transforms[f].apply(Vec2(Double(v.x), Double(v.y)))
                    return SIMD2(Float(q.x), Float(q.y))
                }
            }
            i = j
        }
        return out
    }

    /// Both sides of every cut edge, in map coordinates.
    public func cutSegments() -> [LineSegment] {
        projection.cutEdges.flatMap { e in
            projection.mapSegments(ofEdge: e).map { LineSegment($0.0, $0.1, face: mesh.faceCount) }
        }
    }

    /// A group's outline (see `outline(ofGroup:)`) in map coordinates.
    public func outlineSegments(ofGroup g: Int) -> [LineSegment] {
        outline(ofGroup: g).map { LineSegment($0[0], $0[1], face: mesh.faceCount) }
    }
}
