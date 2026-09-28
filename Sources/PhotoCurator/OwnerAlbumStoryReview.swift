import Foundation

enum OwnerAlbumStoryKind: String, Codable, Sendable, CaseIterable {
    case journey, outing, people, event, skip

    var shipsAsStory: Bool { self == .journey || self == .outing }
}

/// Owner-reviewed labels for historical album → Story qualification.
/// Lives in Application Support; defaults install from the 2026-09-27 owner pass.
struct OwnerAlbumStoryReview: Codable, Equatable, Sendable {
    var version: Int
    var reviewedAt: String
    var sourceAudit: String
    var labels: [String: OwnerAlbumStoryKind]

    static let currentVersion = 1

    var storyTitles: [String] {
        labels.compactMap { $0.value.shipsAsStory ? $0.key : nil }.sorted()
    }

    func kind(forAlbumTitle title: String) -> OwnerAlbumStoryKind? {
        let key = Self.normalized(title)
        if let exact = labels.first(where: { Self.normalized($0.key) == key })?.value {
            return exact
        }
        return nil
    }

    static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// 2026-09-27 owner classification against the second historical metadata audit.
    static let september2026OwnerPass = OwnerAlbumStoryReview(
        version: currentVersion,
        reviewedAt: "2026-09-27",
        sourceAudit: "2 - Photo Curator Historical Metadata Audit.json",
        labels: [
            "New York": .journey,
            "Images from: Slavsko": .journey,
            "Glasgow": .journey,
            "Images from: Zakarpattya": .journey,
            "Virginia": .journey,
            "Enter-EX2004": .journey,
            "Kiev 2005": .journey,
            "Mariupol2005": .journey,
            "Slavsko3": .journey,
            "In the city": .outing,
            "Chicago": .outing,
            "Madison": .outing,
            "Belosarayka": .outing,
            "night-lviv-gr": .outing,
            "Twin Cities": .outing,
            "Shevchenkivskiy Hay": .outing,
            "First Anna photos": .people,
            "Vanessa": .people,
            "Dulzon": .people,
            "Home": .people,
            "Vitali_Dulzon": .people,
            "SoftServe NewYear 2007": .event,
            "full size": .event,
            "Схід і Захід разом": .event,
            "Старый Львов": .skip,
            "Зима 2006": .skip,
            "Осень 2006": .skip,
            "Lena & CO": .skip,
            "Andrey_Dulzon": .skip,
            "winter 2007": .skip,
            "Uljana": .skip,
            "PhotosFromVideo": .skip,
            "Personal": .skip
        ]
    )
}

enum OwnerAlbumStoryReviewStore {
    static func productionURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Curator/curator/owner-album-story-review.json")
    }

    static func load(url: URL = productionURL(), fileManager: FileManager = .default) throws -> OwnerAlbumStoryReview {
        if !fileManager.fileExists(atPath: url.path) {
            try installDefault(at: url, fileManager: fileManager)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(OwnerAlbumStoryReview.self, from: data)
    }

    static func installDefault(at url: URL = productionURL(),
                               review: OwnerAlbumStoryReview = .september2026OwnerPass,
                               fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(review)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
