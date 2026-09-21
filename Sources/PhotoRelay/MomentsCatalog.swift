import Foundation

/// Derived snapshots only. User titles and inclusion decisions remain in their own store.
struct MomentsCatalog: Codable {
    private static let maximumSize = 96 * 1024 * 1024
    var version = 1
    var updated: Date
    var moments: [PhotoMoment]

    static func load(from url: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumSize else {
            throw PublicationFailure.corruptJournal
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1, Set(value.moments.map(\.id)).count == value.moments.count else {
            throw PublicationFailure.corruptJournal
        }
        return value
    }

    @discardableResult
    mutating func markPublished(momentID: String, albumID: String, date: Date) -> Bool {
        guard !albumID.isEmpty, let index = moments.firstIndex(where: { $0.id == momentID }) else { return false }
        moments[index].publishedAlbumID = albumID
        moments[index].publishedDate = date
        updated = date
        return true
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let lock = try PublicationJournalLock(journal: url)
        defer { withExtendedLifetime(lock) {} }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumSize else { throw PublicationFailure.invalidRequest }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
