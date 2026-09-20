import Foundation

/// User-authored text pins identity and membership, not an automatic boundary hypothesis.
struct MomentGroupingProtection: Equatable {
    static let membershipKey = "curator.namedMomentMembers.v1"
    var ids: Set<String> = []
    var members: [String: Set<String>] = [:]

    static func load(_ defaults: UserDefaults) -> Self {
        let titles = defaults.dictionary(forKey: "curator.momentTitles.v1") ?? [:]
        let descriptions = defaults.dictionary(forKey: "curator.momentDescriptions.v1") ?? [:]
        let ids = Set(titles.keys).union(descriptions.keys)
        let saved = defaults.dictionary(forKey: membershipKey) as? [String: [String]] ?? [:]
        return Self(ids: ids, members: saved.filter { ids.contains($0.key) }.mapValues { Set($0) })
    }

    @MainActor
    static func remember(_ moment: PhotoMoment, defaults: UserDefaults) {
        var saved = defaults.dictionary(forKey: membershipKey) as? [String: [String]] ?? [:]
        // Never shrink a pinned membership when a photo is temporarily unavailable.
        guard saved[moment.id] == nil else { return }
        saved[moment.id] = moment.photos.map(\.id).sorted()
        defaults.set(saved, forKey: membershipKey)
    }

    @MainActor
    static func captureLegacy(_ moments: [PhotoMoment], defaults: UserDefaults) {
        let snapshot = load(defaults)
        for moment in moments where snapshot.ids.contains(moment.id) && snapshot.members[moment.id] == nil {
            remember(moment, defaults: defaults)
        }
    }
}
