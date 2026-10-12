import Foundation
import ZoneAtlas

/// Which timezone borders become cuts.
public enum CutGrouping: String, Sendable, Hashable, CaseIterable, Codable {
    /// Every border between regions whose clocks differ in any season.
    case region
    /// Only borders where the UTC offset differs at the reference date, so
    /// the map's seams follow daylight saving changes.
    case utcOffset

    public var title: String {
        switch self {
        case .region: "Distinct clocks"
        case .utcOffset: "Current UTC offset"
        }
    }
}

/// A set of regions that one unfolded piece of the map stands for.
public struct ZoneGroup: Sendable, Identifiable, Hashable {
    public let id: Int
    public let regions: [Int]
    /// UTC offset in seconds at the grouping's reference date.
    public let utcOffset: Int
    /// Representative region for clocks and names.
    public let primaryRegion: Int
}

public struct ZoneGrouping: Sendable {
    public let groups: [ZoneGroup]
    /// Group index per region.
    public let groupOfRegion: [Int]

    public init(atlas: ZoneAtlas, grouping: CutGrouping, date: Date) {
        let offsets = atlas.regions.map { $0.utcOffset(at: date) }
        switch grouping {
        case .region:
            groups = atlas.regions.map { r in
                ZoneGroup(id: r.id, regions: [r.id], utcOffset: offsets[r.id], primaryRegion: r.id)
            }
            groupOfRegion = atlas.regions.map(\.id)
        case .utcOffset:
            let distinct = Array(Set(offsets)).sorted()
            let index = Dictionary(uniqueKeysWithValues: distinct.enumerated().map { ($1, $0) })
            var members = Array(repeating: [Int](), count: distinct.count)
            for r in atlas.regions { members[index[offsets[r.id]]!].append(r.id) }
            groups = distinct.enumerated().map { i, offset in
                // Name the group after its largest-population-ish region: prefer
                // a non-"Etc" identifier.
                let primary = members[i].first { !atlas.regions[$0].identifier.hasPrefix("Etc/") } ?? members[i][0]
                return ZoneGroup(id: i, regions: members[i], utcOffset: offset, primaryRegion: primary)
            }
            groupOfRegion = offsets.map { index[$0]! }
        }
    }
}
