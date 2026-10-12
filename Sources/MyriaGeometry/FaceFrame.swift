import Foundation

/// Orthonormal 2D coordinate system in the plane of one polyhedron face.
///
/// Sphere points reach the face by gnomonic (central) projection: the ray from
/// the globe's centre through the point is intersected with the face plane.
/// Great circles become straight lines, so the region of the sphere that maps
/// into the face is the spherical polygon spanned by the face's vertices.
public struct FaceFrame: Sendable {
    /// Outward unit normal of the face plane.
    public let normal: Vec3
    /// Distance from the globe's centre to the face plane.
    public let planeDistance: Double
    /// Centroid of the face vertices; the local origin.
    public let origin: Vec3
    /// Local x axis: east at the face centre, projected into the plane.
    public let xAxis: Vec3
    /// Local y axis: north at the face centre, projected into the plane.
    public let yAxis: Vec3
    /// Face vertices in local coordinates, counter-clockwise.
    public let localVertices: [Vec2]

    public init(vertices: [Vec3]) {
        let n = Polyhedron.newellNormal(vertices).normalized
        let origin = vertices.reduce(Vec3.zero, +) / Double(vertices.count)
        normal = n
        planeDistance = vertices.reduce(0) { $0 + n.dot($1) } / Double(vertices.count)
        self.origin = origin
        let east = Spherical.tangentFrame(at: origin).east
        let x = (east - n * east.dot(n)).normalized
        xAxis = x
        yAxis = n.cross(x)
        localVertices = vertices.map { Vec2(($0 - origin).dot(x), ($0 - origin).dot(n.cross(x))) }
    }

    /// Local coordinates of a point lying in the face plane.
    @inlinable public func local(ofPlanePoint p: Vec3) -> Vec2 {
        let d = p - origin
        return Vec2(d.dot(xAxis), d.dot(yAxis))
    }

    /// The plane point at local coordinates `q`.
    @inlinable public func planePoint(_ q: Vec2) -> Vec3 {
        origin + xAxis * q.x + yAxis * q.y
    }

    /// Gnomonic projection of a sphere direction onto the face plane, or nil
    /// for directions in the hemisphere facing away from the face.
    @inlinable public func gnomonic(_ v: Vec3, minimumCosine: Double = 1e-6) -> Vec2? {
        let c = normal.dot(v)
        guard c > minimumCosine * v.length else { return nil }
        return local(ofPlanePoint: v * (planeDistance / c))
    }

    /// The sphere point that projects to local coordinates `q`.
    @inlinable public func spherePoint(_ q: Vec2) -> Vec3 {
        planePoint(q).normalized
    }

    /// Area of the flat face.
    public var area: Double { Planar.signedArea(localVertices) }
}
