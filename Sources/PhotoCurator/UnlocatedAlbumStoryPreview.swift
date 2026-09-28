import Foundation
import Photos

/// Gated Diagnostics preview: owner-reviewed albums → Moments → prototype Stories.
/// Never writes to `stories` / `rebuildStories`. Private JSON only.
enum UnlocatedAlbumStoryPreview {
    struct Summary: Equatable, Sendable {
        var eligibleAlbums: Int
        var matchedAlbums: Int
        var proposedStories: Int
        var claimedMomentsExcluded: Int
        var unmatchedTitles: [String]
    }

    enum PreviewError: LocalizedError {
        case unauthorized(PHAuthorizationStatus)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized(let status):
                return "PhotoKit access is \(HistoricalMetadataAudit.authorizationLabel(status)). Allow Photos for Photo Curator before exporting the album Story preview."
            case .writeFailed(let detail):
                return "Could not write the private album Story preview (\(detail))."
            }
        }
    }

    static func collectAlbums(matching titles: [String],
                              cutoff: Date = HistoricalMetadataAudit.historicalCutoff) throws -> [UnlocatedAlbumStoryBuilder.AlbumMembership] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else { throw PreviewError.unauthorized(status) }
        let wanted = Set(titles.map(OwnerAlbumStoryReview.normalized))
        guard !wanted.isEmpty else { return [] }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate < %@",
            PHAssetMediaType.image.rawValue,
            cutoff as NSDate
        )

        var byTitle: [String: Set<String>] = [:]
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { album, _, _ in
            autoreleasepool {
                let title = (album.localizedTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, wanted.contains(OwnerAlbumStoryReview.normalized(title)) else { return }
                if isUnderPhotoCurator(album) { return }
                let members = PHAsset.fetchAssets(in: album, options: options)
                guard members.count > 0 else { return }
                var ids = byTitle[title] ?? []
                members.enumerateObjects { asset, _, _ in
                    ids.insert(asset.localIdentifier)
                }
                byTitle[title] = ids
            }
        }
        return byTitle.map { UnlocatedAlbumStoryBuilder.AlbumMembership(title: $0.key, assetIDs: $0.value) }
            .sorted { $0.assetIDs.count > $1.assetIDs.count }
    }

    static func build(moments: [UnlocatedAlbumStoryBuilder.MomentMembership],
                      albums: [UnlocatedAlbumStoryBuilder.AlbumMembership],
                      review: OwnerAlbumStoryReview,
                      claimedMomentIDs: Set<String>) -> ([CurationStory], Summary) {
        let stories = UnlocatedAlbumStoryBuilder.stories(
            moments: moments, albums: albums, review: review, claimedMomentIDs: claimedMomentIDs)
        let matchedKeys = Set(stories.map { UnlocatedAlbumStoryBuilder.albumMatchKey(fromDisplayTitle: $0.placeID) })
        let unmatched = review.storyTitles.filter { title in
            let display = UnlocatedAlbumStoryBuilder.displayTitle(
                albumTitle: title, start: .distantPast, end: .distantPast, disambiguateByYear: false)
            return !matchedKeys.contains(OwnerAlbumStoryReview.normalized(display))
        }
        let summary = Summary(
            eligibleAlbums: review.storyTitles.count,
            matchedAlbums: review.storyTitles.count - unmatched.count,
            proposedStories: stories.count,
            claimedMomentsExcluded: claimedMomentIDs.count,
            unmatchedTitles: unmatched
        )
        return (stories, summary)
    }

    static func write(stories: [CurationStory],
                      summary: Summary,
                      review: OwnerAlbumStoryReview,
                      albums: [UnlocatedAlbumStoryBuilder.AlbumMembership],
                      to destination: URL,
                      fileManager: FileManager = .default) throws {
        let albumSizes = Dictionary(uniqueKeysWithValues: albums.map {
            (OwnerAlbumStoryReview.normalized($0.title), $0.assetIDs.count)
        })
        let payload: [String: Any] = [
            "shipping": false,
            "provenance": "ownerReviewedAlbum",
            "reviewVersion": review.version,
            "reviewedAt": review.reviewedAt,
            "sourceAudit": review.sourceAudit,
            "eligibleAlbums": summary.eligibleAlbums,
            "matchedAlbums": summary.matchedAlbums,
            "proposedStories": summary.proposedStories,
            "claimedMomentsExcluded": summary.claimedMomentsExcluded,
            "unmatchedTitles": summary.unmatchedTitles,
            "maxGapDays": UnlocatedAlbumStoryBuilder.defaultMaxGap / 86_400,
            "stories": stories.map { story -> [String: Any] in
                let spanDays = max(0, story.end.timeIntervalSince(story.start) / 86_400)
                return [
                    "id": story.id,
                    "title": story.placeID,
                    "kind": story.kind.rawValue,
                    "start": ISO8601DateFormatter().string(from: story.start),
                    "end": ISO8601DateFormatter().string(from: story.end),
                    "spanDays": (spanDays * 10).rounded() / 10,
                    "momentCount": story.momentIDs.count,
                    "momentIDs": story.momentIDs,
                    "albumHistoricalPhotos": albumSizes[OwnerAlbumStoryReview.normalized(story.placeID)] ?? 0,
                    "stops": [] as [Any]
                ]
            },
            "privacy": "Private owner preview. Contains album titles and Moment identifiers. Do not share or commit."
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            throw PreviewError.writeFailed(error.localizedDescription)
        }
    }

    static func export(moments: [UnlocatedAlbumStoryBuilder.MomentMembership],
                       claimedMomentIDs: Set<String>,
                       to destination: URL,
                       review: OwnerAlbumStoryReview? = nil) throws -> Summary {
        let review = try review ?? OwnerAlbumStoryReviewStore.load()
        let albums = try collectAlbums(matching: review.storyTitles)
        let (stories, summary) = build(moments: moments, albums: albums, review: review,
                                       claimedMomentIDs: claimedMomentIDs)
        try write(stories: stories, summary: summary, review: review, albums: albums, to: destination)
        return summary
    }

    private static func isUnderPhotoCurator(_ album: PHAssetCollection) -> Bool {
        var ancestors: [String] = []
        var visited = Set<String>()
        var collections: [PHCollection] = [album]
        while let collection = collections.popLast() {
            let parents = PHCollectionList.fetchCollectionListsContaining(collection, options: nil)
            parents.enumerateObjects { parent, _, _ in
                if visited.insert(parent.localIdentifier).inserted {
                    ancestors.append(parent.localizedTitle ?? "")
                    collections.append(parent)
                }
            }
        }
        return ancestors.contains { $0.caseInsensitiveCompare("Photo Curator") == .orderedSame }
    }
}
