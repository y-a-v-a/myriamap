import Foundation

/// One region of the timezone map: an area whose clocks have agreed since the
/// data's reference date, named after a representative IANA zone.
public struct TimeZoneRegion: Sendable, Identifiable, Hashable {
    public let id: Int
    public let identifier: String
    public let timeZone: TimeZone
    /// Readable place name: "America/New_York" becomes "New York".
    public let placeName: String

    public init(id: Int, identifier: String) {
        self.id = id
        self.identifier = identifier
        timeZone = TimeZone(identifier: identifier) ?? Self.fallbackTimeZone(identifier)
        let last = identifier.split(separator: "/").last.map(String.init) ?? identifier
        placeName = identifier.hasPrefix("Etc/") ? "Open ocean" : last.replacingOccurrences(of: "_", with: " ")
    }

    /// Seconds east of UTC at `date`, daylight saving included.
    public func utcOffset(at date: Date) -> Int { timeZone.secondsFromGMT(for: date) }

    public func isDaylightSavingTime(at date: Date) -> Bool { timeZone.isDaylightSavingTime(for: date) }

    /// "UTC+05:30", "UTC−03:00", "UTC±00:00".
    public func offsetLabel(at date: Date) -> String { Self.offsetLabel(seconds: utcOffset(at: date)) }

    public func abbreviation(at date: Date) -> String {
        timeZone.abbreviation(for: date) ?? offsetLabel(at: date)
    }

    /// Wall-clock time in the region, e.g. "14:05".
    public func clockTime(at date: Date, seconds: Bool = false) -> String {
        // UTC plus the offset in force: what a calendar in this zone reads,
        // without building one for every clock on every update.
        let s = localSecondOfDay(at: date)
        let hm = Self.twoDigits(s / 3600) + ":" + Self.twoDigits(s / 60 % 60)
        return seconds ? hm + ":" + Self.twoDigits(s % 60) : hm
    }

    /// Fractional local hour of day in [0, 24).
    public func localHour(at date: Date) -> Double {
        Double(localSecondOfDay(at: date)) / 3600
    }

    /// Calendar day offset relative to UTC: -1, 0 or +1.
    public func dayOffset(at date: Date) -> Int {
        let t = Int(date.timeIntervalSince1970.rounded(.down))
        return Self.floorDivide(t + utcOffset(at: date), 86_400) - Self.floorDivide(t, 86_400)
    }

    /// Whole seconds since local midnight.
    func localSecondOfDay(at date: Date) -> Int {
        let t = Int(date.timeIntervalSince1970.rounded(.down)) + utcOffset(at: date)
        return t - Self.floorDivide(t, 86_400) * 86_400
    }

    static func floorDivide(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }

    static func twoDigits(_ n: Int) -> String { n < 10 ? "0" + String(n) : String(n) }

    public static func offsetLabel(seconds: Int) -> String {
        if seconds == 0 { return "UTC±00:00" }
        let m = abs(seconds) / 60
        return "UTC" + (seconds > 0 ? "+" : "−") + twoDigits(m / 60) + ":" + twoDigits(m % 60)
    }

    /// For identifiers the system database lacks, fixed offsets like
    /// "Etc/GMT+12" (POSIX sign: west of Greenwich) still resolve.
    static func fallbackTimeZone(_ identifier: String) -> TimeZone {
        if identifier.hasPrefix("Etc/GMT"), let hours = Int(identifier.dropFirst(7)) {
            return TimeZone(secondsFromGMT: -hours * 3600) ?? .gmt
        }
        return .gmt
    }
}
