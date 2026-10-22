import Foundation

/// A 3×3 matrix stored by columns.
public struct Mat3: Hashable, Sendable {
    public var c0: Vec3
    public var c1: Vec3
    public var c2: Vec3

    @inlinable public init(_ c0: Vec3, _ c1: Vec3, _ c2: Vec3) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
    }

    public static let identity = Mat3(.unitX, .unitY, .unitZ)

    @inlinable public func apply(_ v: Vec3) -> Vec3 { c0 * v.x + c1 * v.y + c2 * v.z }

    @inlinable public static func * (a: Mat3, b: Mat3) -> Mat3 { Mat3(a.apply(b.c0), a.apply(b.c1), a.apply(b.c2)) }

    /// Rotation by `angle` about the unit axis `k` (right-hand rule).
    @inlinable public static func rotation(axis k: Vec3, angle: Double) -> Mat3 {
        let c = cos(angle), s = sin(angle), t = 1 - c
        // Rodrigues' formula, column by column.
        return Mat3(Vec3(c + k.x * k.x * t, k.y * k.x * t + k.z * s, k.z * k.x * t - k.y * s),
                    Vec3(k.x * k.y * t - k.z * s, c + k.y * k.y * t, k.z * k.y * t + k.x * s),
                    Vec3(k.x * k.z * t + k.y * s, k.y * k.z * t - k.x * s, c + k.z * k.z * t))
    }

    public static func rotationZ(_ angle: Double) -> Mat3 { rotation(axis: .unitZ, angle: angle) }
}

/// Rigid motion of 3D space.
public struct Pose3: Hashable, Sendable {
    public var rotation: Mat3
    public var translation: Vec3

    @inlinable public init(rotation: Mat3, translation: Vec3) {
        self.rotation = rotation
        self.translation = translation
    }

    public static let identity = Pose3(rotation: .identity, translation: .zero)

    @inlinable public func apply(_ v: Vec3) -> Vec3 { rotation.apply(v) + translation }

    /// A face-local point, which lies in the plane z = 0.
    @inlinable public func apply(_ q: Vec2) -> Vec3 { rotation.c0 * q.x + rotation.c1 * q.y + translation }

    /// `self` applied after `other`.
    @inlinable public func concatenating(_ other: Pose3) -> Pose3 {
        Pose3(rotation: rotation * other.rotation, translation: apply(other.translation))
    }
}

/// Folds an unfolded myriahedron back towards the polyhedron, as in van
/// Wijk's animations: every hinge opens by the same fraction of its
/// dihedral angle, so `fold(1)` is the flat map and `fold(0)` the closed
/// polyhedron, seen from outside its root face.
public struct Folding: Sendable {
    let order: [Int]
    let parent: [Int]
    /// Per face: child-local → parent-local when flat.
    let flat: [Pose3]
    /// Per face: hinge point and direction in parent-local coordinates.
    let hingePoint: [Vec3]
    let hingeAxis: [Vec3]
    /// Per face: signed rotation about the hinge that closes it.
    let closingAngle: [Double]
    /// Faces with large subtrees, in tree order: posed one after another.
    let trunk: [Int]
    /// The rest, as subtrees hanging off the trunk, grouped into batches of
    /// similar size that can be posed in parallel.
    let branches: [[Int]]

    public init(projection: MyriahedralProjection) {
        let mesh = projection.mesh, unfolding = projection.unfolding
        let n = mesh.faceCount
        var flat = Array(repeating: Pose3.identity, count: n)
        var hingePoint = Array(repeating: Vec3.zero, count: n)
        var hingeAxis = Array(repeating: Vec3.unitX, count: n)
        var closingAngle = Array(repeating: 0.0, count: n)

        func local(_ f: Int, _ v: Int) -> Vec2 {
            mesh.frames[f].localVertices[mesh.polyhedron.faces[f].firstIndex(of: v)!]
        }

        for c in 0..<n where unfolding.parent[c] >= 0 {
            let p = unfolding.parent[c]
            let edge = mesh.topology.edges[unfolding.parentEdge[c]]
            // Child-local → parent-local in the flat state.
            let m = unfolding.transforms[p].inverse.concatenating(unfolding.transforms[c])
            flat[c] = Pose3(rotation: .rotationZ(m.angle), translation: Vec3(m.translation.x, m.translation.y, 0))
            let a = local(p, edge.a), b = local(p, edge.b)
            let point = Vec3(a.x, a.y, 0)
            let axis = Vec3(b.x - a.x, b.y - a.y, 0).normalized
            hingePoint[c] = point
            hingeAxis[c] = axis
            // The polyhedron is convex: closing tips the child away from the
            // parent's outward normal (+z in parent-local coordinates).
            let angle = mesh.frames[p].normal.angle(to: mesh.frames[c].normal)
            let probe = flat[c].apply(Planar.centroid(mesh.frames[c].localVertices))
            let tipped = Mat3.rotation(axis: axis, angle: angle).apply(probe - point) + point
            closingAngle[c] = tipped.z <= 0 ? angle : -angle
        }
        order = unfolding.order
        parent = unfolding.parent
        self.flat = flat
        self.hingePoint = hingePoint
        self.hingeAxis = hingeAxis
        self.closingAngle = closingAngle
        (trunk, branches) = Self.split(order: order, parent: parent)
    }

    /// Splits the tree into a trunk of faces whose subtrees exceed a limit
    /// and the subtrees below it, packed into batches.
    static func split(order: [Int], parent: [Int]) -> (trunk: [Int], branches: [[Int]]) {
        let n = order.count
        let batchCount = 4 * ProcessInfo.processInfo.activeProcessorCount
        // Small meshes aren't worth handing to other threads.
        guard n >= 4096, batchCount > 4 else { return (order, []) }
        var size = Array(repeating: 1, count: n)
        for f in order.reversed() where parent[f] >= 0 { size[parent[f]] += size[f] }
        let limit = n / (2 * batchCount)
        var trunk: [Int] = []
        var subtrees: [[Int]] = []
        var subtreeOf = Array(repeating: -1, count: n)
        // Tree order puts parents first, so every subtree comes out in tree
        // order too, and a face below the limit has all its descendants with it.
        for f in order {
            let p = parent[f]
            if p < 0 || size[f] > limit {
                trunk.append(f)
            } else if subtreeOf[p] >= 0 {
                subtreeOf[f] = subtreeOf[p]
                subtrees[subtreeOf[f]].append(f)
            } else {
                subtreeOf[f] = subtrees.count
                subtrees.append([f])
            }
        }
        // Largest first, each into the lightest batch.
        var batches = Array(repeating: [Int](), count: batchCount)
        for subtree in subtrees.sorted(by: { $0.count > $1.count }) {
            let lightest = batches.indices.min { batches[$0].count < batches[$1].count }!
            batches[lightest] += subtree
        }
        return (trunk, batches.filter { !$0.isEmpty })
    }

    /// Face-local → world poses at `unfold` in [0, 1] (0 closed, 1 flat). The
    /// root face stays in the plane z = 0 facing +z.
    public func poses(unfold: Double) -> [Pose3] {
        var poses: [Pose3] = []
        self.poses(unfold: unfold, into: &poses)
        return poses
    }

    /// The poses at `unfold` seen through `camera` (applied after each
    /// pose), written into `poses`, which keeps its storage between frames.
    /// The trunk is posed first, then the branches in parallel.
    public func poses(unfold: Double, camera: Pose3 = .identity, into poses: inout [Pose3]) {
        if poses.count != order.count { poses = Array(repeating: camera, count: order.count) }
        let closing = 1 - min(max(unfold, 0), 1)
        poses.withUnsafeMutableBufferPointer { buffer in
            let out = buffer.baseAddress!
            for f in trunk { pose(f, closing: closing, camera: camera, into: out) }
            guard !branches.isEmpty else { return }
            nonisolated(unsafe) let shared = out
            DispatchQueue.concurrentPerform(iterations: branches.count) { b in
                for f in branches[b] { pose(f, closing: closing, camera: camera, into: shared) }
            }
        }
    }

    /// Poses face `f` from its parent's pose: the parent's pose, then the
    /// hinge closing by `closing` of its angle, then the flat placement.
    @inline(__always)
    private func pose(_ f: Int, closing: Double, camera: Pose3, into poses: UnsafeMutablePointer<Pose3>) {
        let p = parent[f]
        guard p >= 0 else {
            poses[f] = camera
            return
        }
        // The hinge lies in the parent's plane (k.z = 0), which trims
        // Rodrigues' formula.
        let k = hingeAxis[f], h = hingePoint[f], placed = flat[f]
        let angle = closingAngle[f] * closing
        let c = cos(angle), s = sin(angle), t = 1 - c
        let r0 = Vec3(c + k.x * k.x * t, k.x * k.y * t, -k.y * s)
        let r1 = Vec3(k.x * k.y * t, c + k.y * k.y * t, k.x * s)
        let r2 = Vec3(k.y * s, -k.x * s, c)
        // Hinge after flat: the flat rotation is about z, its translation in z = 0.
        let z0 = placed.rotation.c0, z1 = placed.rotation.c1
        let d = placed.translation - h
        let m0 = r0 * z0.x + r1 * z0.y, m1 = r0 * z1.x + r1 * z1.y
        let local = h + r0 * d.x + r1 * d.y
        let parentPose = poses[p], q = parentPose.rotation
        poses[f] = Pose3(rotation: Mat3(q.apply(m0), q.apply(m1), q.apply(r2)),
                         translation: parentPose.apply(local))
    }
}
