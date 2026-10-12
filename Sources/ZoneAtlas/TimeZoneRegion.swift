import Foundation

/// One region of the timezone map: an area whose clocks have agreed since the
/// data's reference date, named after a representative IANA zone.
public struct TimeZoneRegion: Sendable, Identifiable, Hashable {
    public let id: Int
    public let identifier: String
    public let timeZone: TimeZone

    public init(id: Int, identifier: String) {
        self.id = id
        self.identifier = identifier
        timeZone = TimeZone(identifier: identifier) ?? Self.fallbackTimeZone(identifier)
    }

    /// Readable place name: "America/New_York" becomes "New York".
    public var placeName: String {
        let last = identifier.split(separator: "/").last.map(String.init) ?? identifier
        if identifier.hasPrefix("Etc/") { return "Open ocean" }
        return last.replacingOccurrences(of: "_", with: " ")
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return seconds ? hm + String(format: ":%02d", c.second ?? 0) : hm
    }

    /// Fractional local hour of day in [0, 24).
    public func localHour(at date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }

    /// Calendar day offset relative to UTC: -1, 0 or +1.
    public func dayOffset(at date: Date) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var local = utc
        local.timeZone = timeZone
        let u = utc.dateComponents([.year, .month, .day], from: date)
        let l = local.dateComponents([.year, .month, .day], from: date)
        guard let ud = utc.date(from: u), let ld = utc.date(from: l) else { return 0 }
        return Int((ld.timeIntervalSince(ud) / 86_400).rounded())
    }

    public static func offsetLabel(seconds: Int) -> String {
        if seconds == 0 { return "UTC±00:00" }
        let sign = seconds > 0 ? "+" : "−"
        let m = abs(seconds) / 60
        return String(format: "UTC%@%02d:%02d", sign, m / 60, m % 60)
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
