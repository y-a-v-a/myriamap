import Foundation

/// A 3×3 matrix stored by columns.
public struct Mat3: Hashable, Sendable {
    public var c0: Vec3
    public var c1: Vec3
    public var c2: Vec3

    public init(_ c0: Vec3, _ c1: Vec3, _ c2: Vec3) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
    }

    public static let identity = Mat3(.unitX, .unitY, .unitZ)

    @inlinable public func apply(_ v: Vec3) -> Vec3 { c0 * v.x + c1 * v.y + c2 * v.z }

    @inlinable public static func * (a: Mat3, b: Mat3) -> Mat3 { Mat3(a.apply(b.c0), a.apply(b.c1), a.apply(b.c2)) }

    /// Rotation by `angle` about the unit axis `k` (right-hand rule).
    public static func rotation(axis k: Vec3, angle: Double) -> Mat3 {
        let c = cos(angle), s = sin(angle)
        func r(_ v: Vec3) -> Vec3 { v * c + k.cross(v) * s + k * (k.dot(v) * (1 - c)) }
        return Mat3(r(.unitX), r(.unitY), r(.unitZ))
    }

    public static func rotationZ(_ angle: Double) -> Mat3 { rotation(axis: .unitZ, angle: angle) }
}

/// Rigid motion of 3D space.
public struct Pose3: Hashable, Sendable {
    public var rotation: Mat3
    public var translation: Vec3

    public init(rotation: Mat3, translation: Vec3) {
        self.rotation = rotation
        self.translation = translation
    }

    public static let identity = Pose3(rotation: .identity, translation: .zero)

    @inlinable public func apply(_ v: Vec3) -> Vec3 { rotation.apply(v) + translation }

    /// A face-local point, which lies in the plane z = 0.
    @inlinable public func apply(_ q: Vec2) -> Vec3 { rotation.c0 * q.x + rotation.c1 * q.y + translation }

    /// `self` applied after `other`.
    public func concatenating(_ other: Pose3) -> Pose3 {
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
    }

    /// Face-local → world poses at `unfold` in [0, 1] (0 closed, 1 flat). The
    /// root face stays in the plane z = 0 facing +z.
    public func poses(unfold: Double) -> [Pose3] {
        var poses = Array(repeating: Pose3.identity, count: order.count)
        let closing = 1 - min(max(unfold, 0), 1)
        for f in order {
            let p = parent[f]
            guard p >= 0 else { continue }
            let rotation = Mat3.rotation(axis: hingeAxis[f], angle: closingAngle[f] * closing)
            let hinge = Pose3(rotation: rotation, translation: hingePoint[f] - rotation.apply(hingePoint[f]))
            poses[f] = poses[p].concatenating(hinge).concatenating(flat[f])
        }
        return poses
    }
}
