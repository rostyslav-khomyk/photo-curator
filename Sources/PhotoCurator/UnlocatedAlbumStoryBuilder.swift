import Foundation

/// Builds gated unlocated Stories from owner-reviewed album membership.
/// Does not invent GPS routes. Moments remain the membership authority.
enum UnlocatedAlbumStoryBuilder {
    /// Matches JourneyStoryBuilder's seven-day gap: a longer pause starts a new Story.
    static let defaultMaxGap: TimeInterval = 7 * 24 * 60 * 60

    struct MomentMembership: Equatable, Sendable {
        let id: String
        let start: Date
        let end: Date
        let assetIDs: Set<String>
    }

    struct AlbumMembership: Equatable, Sendable {
        let title: String
        let assetIDs: Set<String>
    }

    /// Strips Photos "Images from: …" wrappers and optionally years for multi-cluster albums.
    static func displayTitle(albumTitle: String, start: Date, end: Date,
                             disambiguateByYear: Bool,
                             calendar: Calendar = .current) -> String {
        var title = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = title.range(of: #"^images from:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard disambiguateByYear, !title.isEmpty else { return title }
        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)
        if startYear == endYear { return "\(title) · \(startYear)" }
        return "\(title) · \(startYear)–\(endYear)"
    }

    /// Base album key for matching preview titles after display formatting.
    static func albumMatchKey(fromDisplayTitle placeID: String) -> String {
        var base = placeID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = base.range(of: #" · \d{4}(–\d{4})?$"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        return OwnerAlbumStoryReview.normalized(base)
    }

    /// Eligible albums only (journey / outing). Skips people, event, and skip labels.
    /// Moments already claimed by GPS journeys are excluded when `claimedMomentIDs` is provided.
    /// Matched Moments are split into separate Stories when the gap between consecutive
    /// Moments exceeds `maxGap` (default seven days).
    static func stories(moments: [MomentMembership],
                        albums: [AlbumMembership],
                        review: OwnerAlbumStoryReview,
                        claimedMomentIDs: Set<String> = [],
                        maxGap: TimeInterval = defaultMaxGap,
                        calendar: Calendar = .current) -> [CurationStory] {
        let available = moments.filter { !claimedMomentIDs.contains($0.id) }
        var usedMoments = Set<String>()
        var results: [CurationStory] = []

        for album in albums.sorted(by: { $0.assetIDs.count > $1.assetIDs.count }) {
            guard let kindLabel = review.kind(forAlbumTitle: album.title), kindLabel.shipsAsStory else { continue }
            guard !album.assetIDs.isEmpty else { continue }
            let matched = available.filter { moment in
                !usedMoments.contains(moment.id) && overlaps(moment.assetIDs, album.assetIDs)
            }.sorted { $0.start < $1.start }
            let clusters = cluster(matched, maxGap: maxGap)
            guard !clusters.isEmpty else { continue }
            let storyKind: StoryKind = kindLabel == .journey ? .journey : .outing
            let albumTitle = album.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let disambiguate = clusters.count > 1
            for group in clusters {
                guard let first = group.first, let last = group.last else { continue }
                let ids = group.map(\.id)
                usedMoments.formUnion(ids)
                let title = displayTitle(albumTitle: albumTitle, start: first.start, end: last.end,
                                         disambiguateByYear: disambiguate, calendar: calendar)
                let fingerprint = "album|\(OwnerAlbumStoryReview.normalized(albumTitle))|\(ids.joined(separator: "|"))"
                results.append(CurationStory(
                    id: "story-" + MomentContinuity.digest(Data(fingerprint.utf8)),
                    start: first.start,
                    end: last.end,
                    momentIDs: ids,
                    placeID: title,
                    kind: storyKind,
                    stops: []
                ))
            }
        }
        return results.sorted { $0.start > $1.start }
    }

    /// Append album Stories after GPS/place Stories without reusing Moments.
    static func merging(base: [CurationStory], albumStories: [CurationStory]) -> [CurationStory] {
        var claimed = Set(base.flatMap(\.momentIDs))
        var merged = base
        for story in albumStories {
            let ids = story.momentIDs.filter { !claimed.contains($0) }
            guard !ids.isEmpty else { continue }
            claimed.formUnion(ids)
            if ids.count == story.momentIDs.count {
                merged.append(story)
            } else {
                merged.append(CurationStory(
                    id: story.id + "-partial",
                    start: story.start,
                    end: story.end,
                    momentIDs: ids,
                    placeID: story.placeID,
                    kind: story.kind,
                    stops: story.stops
                ))
            }
        }
        return merged.sorted { $0.start > $1.start }
    }

    /// Split chronologically ordered Moments wherever the idle gap exceeds `maxGap`.
    static func cluster(_ moments: [MomentMembership],
                        maxGap: TimeInterval = defaultMaxGap) -> [[MomentMembership]] {
        guard !moments.isEmpty else { return [] }
        let ordered = moments.sorted { $0.start < $1.start }
        var groups: [[MomentMembership]] = [[ordered[0]]]
        for moment in ordered.dropFirst() {
            guard let previous = groups[groups.count - 1].last else { continue }
            let gap = moment.start.timeIntervalSince(previous.end)
            if gap > maxGap {
                groups.append([moment])
            } else {
                groups[groups.count - 1].append(moment)
            }
        }
        return groups
    }

    /// A Moment joins an album when it shares enough members without requiring full containment.
    static func overlaps(_ momentAssets: Set<String>, _ albumAssets: Set<String>) -> Bool {
        let shared = momentAssets.intersection(albumAssets).count
        guard shared > 0 else { return false }
        if shared >= 10 { return true }
        if shared >= 3, !momentAssets.isEmpty,
           Double(shared) / Double(momentAssets.count) >= 0.25 { return true }
        if momentAssets.count <= 4, shared == momentAssets.count { return true }
        return false
    }
}
