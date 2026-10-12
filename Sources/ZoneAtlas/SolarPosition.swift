import Foundation
import MyriaGeometry

/// Low-precision solar ephemeris (about 0.01° over decades), enough to draw
/// the day/night terminator.
public enum SolarPosition {
    /// The point on Earth where the Sun is directly overhead at `date`.
    public static func subsolarPoint(at date: Date) -> GeoPoint {
        // Days since J2000.0 (2000-01-01 12:00 TT, approximated as UTC).
        let n = date.timeIntervalSince1970 / 86_400 - 10_957.5
        let rad = Double.pi / 180
        let meanLongitude = 280.460 + 0.9856474 * n
        let meanAnomaly = (357.528 + 0.9856003 * n) * rad
        let eclipticLongitude = (meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly)) * rad
        let obliquity = (23.439 - 0.0000004 * n) * rad
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude)) / rad
        let gmst = 280.46061837 + 360.98564736629 * n
        return GeoPoint(latitude: declination / rad,
                        longitude: Spherical.normalizeLongitude(rightAscension - gmst))
    }

    /// Unit vector towards the Sun from the centre of the Earth.
    public static func sunDirection(at date: Date) -> Vec3 { subsolarPoint(at: date).unitVector }

    /// Solar elevation in degrees at a location.
    public static func elevation(at p: GeoPoint, date: Date) -> Double {
        asin(max(-1, min(1, p.unitVector.dot(sunDirection(at: date))))) * 180 / .pi
    }
}
