import Foundation
import MyriaGeometry

extension MyriaMap {
    /// The hinge geometry for folding this map back into a globe.
    public func folding() -> Folding { Folding(projection: projection) }

    /// The map partly folded back towards the globe, seen along -z with a
    /// gentle tilt that vanishes as the map lies flat.
    ///
    /// Faces are painted far to near in depth buckets; within a bucket the
    /// fills are batched per colour, so even fine meshes animate smoothly.
    /// - Parameters:
    ///   - unfold: 0 is the closed globe, 1 the flat map.
    ///   - tilt: camera elevation (radians) while closed.
    public func foldedScene(unfold: Double, folding: Folding, options: SceneOptions, tilt: Double = 0.35,
                            buckets: Int = 48) -> MapScene {
        let style = options.style
        let poses = folding.poses(unfold: unfold)
        let closed = 1 - min(max(unfold, 0), 1)
        let tiltRotation = Mat3.rotation(axis: .unitX, angle: tilt * closed)
        // Tilt about the globe's centre (behind the root face) so the closed
        // globe stays centred on the map's origin.
        let pivot = Vec3(0, 0, -closed)
        let camera = Pose3(rotation: tiltRotation, translation: pivot - tiltRotation.apply(pivot))
        let slots = groupColorSlots(slotCount: 5)
        let groupColor = slots.map { style.zoneColor(slot: $0) }
        func over(_ top: RGBA, _ bottom: RGBA) -> RGBA {
            RGBA(top.r * top.a + bottom.r * (1 - top.a), top.g * top.a + bottom.g * (1 - top.a),
                 top.b * top.a + bottom.b * (1 - top.a))
        }
        let shade = style.surface.mixed(with: RGBA(0, 0, 0), 0.6)

        let n = mesh.faceCount
        var depth = Array(repeating: 0.0, count: n)
        var facing = Array(repeating: true, count: n)
        for f in 0..<n {
            let pose = poses[f]
            depth[f] = camera.apply(pose.apply(Planar.centroid(mesh.frames[f].localVertices))).z
            facing[f] = tiltRotation.apply(pose.rotation.c2).z >= 0
        }
        let lo = depth.min() ?? 0, hi = depth.max() ?? 1
        let span = max(hi - lo, 1e-9)

        struct Key: Hashable { let bucket: Int; let layer: Int; let color: RGBA }
        var batches: [Key: [[Vec2]]] = [:]
        func project(_ ring: [Vec2], _ f: Int) -> [Vec2] {
            ring.map { q in
                let p = camera.apply(poses[f].apply(q))
                return Vec2(p.x, p.y)
            }
        }
        for f in 0..<n {
            let bucket = min(buckets - 1, Int((depth[f] - lo) / span * Double(buckets)))
            let dominant = faceGroups[f]
            for fill in overlay.zoneFills[f] {
                var color = groupColor[grouping.groupOfRegion[fill.region]]
                if !facing[f] { color = color.mixed(with: shade, 0.55) }
                batches[Key(bucket: bucket, layer: 0, color: color), default: []] += fill.rings.map { project($0, f) }
            }
            if options.showLand, !overlay.landFills[f].isEmpty, dominant >= 0 {
                var color = over(style.land, groupColor[dominant])
                if !facing[f] { color = color.mixed(with: shade, 0.55) }
                batches[Key(bucket: bucket, layer: 1, color: color), default: []] += overlay.landFills[f].map { project($0, f) }
            }
        }
        let paths = batches.keys
            .sorted { ($0.bucket, $0.layer, $0.color.hex) < ($1.bucket, $1.layer, $1.color.hex) }
            .map { key in
                // A hairline in the fill colour hides seams between faces.
                ScenePath(role: key.layer == 0 ? .zone : .land, subpaths: batches[key]!, closed: true,
                          fill: key.color, stroke: key.color, lineWidth: 0.6)
            }
        var bounds = projection.bounds
        bounds.include(Rect2(minX: -1.1, minY: -1.25, maxX: 1.1, maxY: 1.25))
        return MapScene(bounds: bounds, background: style.page, paths: paths, texts: [])
    }
}
