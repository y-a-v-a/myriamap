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
        let shade = style.surface.mixed(with: RGBA(0, 0, 0), 0.6)

        // Every colour a face can take, numbered once, so batches are keyed
        // by small integers instead of hashed colours: per group the zone
        // fill and the land over it, each lit (1) or turned away (0).
        var palette: [RGBA] = []
        var paletteIndex: [RGBA: Int] = [:]
        func colorID(_ c: RGBA) -> Int {
            if let i = paletteIndex[c] { return i }
            paletteIndex[c] = palette.count
            palette.append(c)
            return palette.count - 1
        }
        let groupColor = colorSlots.map { style.zoneColor(slot: $0) }
        let zoneColor = groupColor.map { c in [colorID(c.mixed(with: shade, 0.55)), colorID(c)] }
        let landColor = groupColor.map { c in
            let land = style.land.composited(over: c)
            return [colorID(land.mixed(with: shade, 0.55)), colorID(land)]
        }
        // Within a depth bucket and layer, paint colours in a fixed order.
        let colorOrder = palette.indices.sorted { a, b in
            func bytes(_ c: RGBA) -> [Int] { [c.r, c.g, c.b].map { Int(($0 * 255).rounded()) } }
            let (x, y) = (bytes(palette[a]), bytes(palette[b]))
            return x != y ? x.lexicographicallyPrecedes(y) : a < b
        }

        // Face-local → view: the face's pose followed by the camera, keeping x and y.
        let n = mesh.faceCount
        var views = [Affine2](repeating: Affine2(Pose3.identity), count: n)
        var depth = Array(repeating: 0.0, count: n)
        var facing = Array(repeating: true, count: n)
        for f in 0..<n {
            let pose = poses[f]
            views[f] = Affine2(camera.concatenating(pose))
            depth[f] = camera.apply(pose.apply(Planar.centroid(mesh.frames[f].localVertices))).z
            facing[f] = tiltRotation.apply(pose.rotation.c2).z >= 0
        }
        let lo = depth.min() ?? 0, hi = depth.max() ?? 1
        let span = max(hi - lo, 1e-9)

        // Batches indexed by (bucket, layer, colour); layer 0 is zone fills, 1 land.
        let colors = palette.count
        var batches = Array(repeating: [[Vec2]](), count: buckets * 2 * colors)
        for f in 0..<n {
            let bucket = min(buckets - 1, Int((depth[f] - lo) / span * Double(buckets)))
            let lit = facing[f] ? 1 : 0
            let view = views[f]
            for fill in overlay.zoneFills[f] {
                let c = zoneColor[grouping.groupOfRegion[fill.region]][lit]
                for ring in fill.rings { batches[(bucket * 2) * colors + c].append(ring.map(view.apply)) }
            }
            let dominant = faceGroups[f]
            if options.showLand, dominant >= 0 {
                let c = landColor[dominant][lit]
                for ring in overlay.landFills[f] { batches[(bucket * 2 + 1) * colors + c].append(ring.map(view.apply)) }
            }
        }
        var paths: [ScenePath] = []
        for bucket in 0..<buckets {
            for layer in 0..<2 {
                for c in colorOrder where !batches[(bucket * 2 + layer) * colors + c].isEmpty {
                    // A hairline in the fill colour hides seams between faces.
                    paths.append(ScenePath(role: layer == 0 ? .zone : .land,
                                           subpaths: batches[(bucket * 2 + layer) * colors + c], closed: true,
                                           fill: palette[c], stroke: palette[c], lineWidth: 0.6))
                }
            }
        }
        var bounds = projection.bounds
        bounds.include(Rect2(minX: -1.1, minY: -1.25, maxX: 1.1, maxY: 1.25))
        return MapScene(bounds: bounds, background: style.page, paths: paths, texts: [])
    }
}

/// The x and y rows of a 3D pose, for points in a face's plane (z = 0).
private struct Affine2 {
    let xx, xy, tx, yx, yy, ty: Double

    init(_ pose: Pose3) {
        let r = pose.rotation
        (xx, xy, tx) = (r.c0.x, r.c1.x, pose.translation.x)
        (yx, yy, ty) = (r.c0.y, r.c1.y, pose.translation.y)
    }

    func apply(_ q: Vec2) -> Vec2 { Vec2(xx * q.x + xy * q.y + tx, yx * q.x + yy * q.y + ty) }
}
