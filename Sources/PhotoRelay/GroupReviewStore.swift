import Foundation

struct SavedReviewGroup: Codable, Equatable {
    let id: String
    var title: String
    var members: Set<String>
    var sourceText: [String: String]? = nil
}

struct GroupReviewArchive: Codable {
    var version = 1
    var revision = 0
    var groups: [SavedReviewGroup] = []

    func applying(to proposal: GroupingProposal) -> GroupingProposal {
        let photos = Dictionary(uniqueKeysWithValues: proposal.groups.flatMap(\.photos).map { ($0.id, $0) })
        var assigned = Set<String>()
        var result: [SuggestedPhotoGroup] = []
        for saved in groups {
            let members = saved.members.compactMap { photos[$0] }.sorted { $0.id < $1.id }
            guard !members.isEmpty else { continue }
            assigned.formUnion(members.map(\.id))
            result.append(SuggestedPhotoGroup(id: saved.id, photos: members,
                explanations: Dictionary(uniqueKeysWithValues: members.map { ($0.id, "Saved group membership chosen by you; no location inferred from this edit.") }),
                title: saved.title))
        }
        for automatic in proposal.groups {
            let remaining = automatic.photos.filter { !assigned.contains($0.id) }
            guard !remaining.isEmpty else { continue }
            var group = automatic
            group.photos = remaining
            // A removed anchor must not remain the identity/source of a residual group.
            group = SuggestedPhotoGroup(id: "auto:" + remaining[0].id, photos: remaining,
                explanations: automatic.explanations,
                inferredLocationSources: automatic.inferredLocationSources.filter { pair in
                    remaining.contains { $0.id == pair.key } && remaining.contains { $0.id == pair.value }
                }, title: automatic.title)
            result.append(group)
        }
        return GroupingProposal(groups: result, suspiciousTimes: proposal.suspiciousTimes)
    }
}

struct GroupReviewStore {
    let url: URL

    /// An explicit whole-Moment merge; revisions prevent overwriting another review.
    func merge(_ moments: [PhotoMoment], title: String, sourceText: [String: String], expectedRevision: Int) throws -> SavedReviewGroup {
        let lock = try PublicationJournalLock(journal: url)
        defer { withExtendedLifetime(lock) {} }
        var archive = try load()
        guard archive.revision == expectedRevision else { throw PublicationFailure.conflictingOperation }
        let ids = Set(moments.map(\.id))
        let assets = moments.flatMap(\.photos).map(\.id)
        guard moments.count >= 2, ids.count == moments.count, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 200, moments.allSatisfy({ !$0.photos.isEmpty }),
              assets.count == Set(assets).count else { throw PublicationFailure.invalidRequest }
        var members = Set(assets)
        var provenance = sourceText
        // A saved group may include unavailable assets; do not drop those on merge.
        for group in archive.groups where ids.contains(group.id) {
            members.formUnion(group.members)
            for (key, value) in group.sourceText ?? [:] { provenance[key] = value }
        }
        let merged = SavedReviewGroup(id: UUID().uuidString, title: title, members: members, sourceText: provenance)
        archive.groups = archive.groups.compactMap { old in
            var group = old
            group.members.subtract(members)
            return group.members.isEmpty ? nil : group
        }
        archive.groups.append(merged)
        archive.revision += 1
        let data = try JSONEncoder().encode(archive)
        guard data.count <= 16 * 1024 * 1024 else { throw PublicationFailure.invalidRequest }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        NotificationCenter.default.post(name: Notification.Name("PhotoRelayGroupReviewChanged"), object: nil)
        return merged
    }

    func load() throws -> GroupReviewArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return GroupReviewArchive() }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1024 * 1024 else {
            throw PublicationFailure.corruptJournal
        }
        let archive = try JSONDecoder().decode(GroupReviewArchive.self, from: Data(contentsOf: url))
        guard archive.version == 1, archive.revision >= 0,
              Set(archive.groups.map(\.id)).count == archive.groups.count,
              archive.groups.allSatisfy({ !$0.id.isEmpty && !$0.members.isEmpty && $0.title.count <= 200 }),
              Set(archive.groups.flatMap(\.members)).count == archive.groups.reduce(0, { $0 + $1.members.count }) else {
            throw PublicationFailure.corruptJournal
        }
        return archive
    }

    /// Replace only the explicitly reviewed visible membership, preserving hidden members.
    func save(_ groups: [SuggestedPhotoGroup], visible: Set<String>, expectedRevision: Int) throws -> GroupReviewArchive {
        let lock = try PublicationJournalLock(journal: url)
        defer { withExtendedLifetime(lock) {} }
        var archive = try load()
        guard archive.revision == expectedRevision else { throw PublicationFailure.conflictingOperation }
        let all = groups.flatMap(\.photos).map(\.id)
        guard Set(all) == visible, all.count == visible.count,
              Set(groups.map(\.id)).count == groups.count, groups.allSatisfy({ !$0.photos.isEmpty }) else {
            throw PublicationFailure.invalidRequest
        }
        let known = Set(archive.groups.map(\.id))
        let provenance = Dictionary(uniqueKeysWithValues: archive.groups.map { ($0.id, $0.sourceText) })
        archive.groups = archive.groups.compactMap { old in
            var value = old
            value.members.subtract(visible)
            return value.members.isEmpty ? nil : value
        }
        for group in groups {
            let id = known.contains(group.id) ? group.id : UUID().uuidString
            let title = String(group.title.prefix(200))
            if let index = archive.groups.firstIndex(where: { $0.id == id }) {
                archive.groups[index].members.formUnion(group.photos.map(\.id))
                archive.groups[index].title = title
            } else {
                archive.groups.append(SavedReviewGroup(id: id, title: title, members: Set(group.photos.map(\.id)), sourceText: provenance[id] ?? nil))
            }
        }
        archive.revision += 1
        let data = try JSONEncoder().encode(archive)
        guard data.count <= 16 * 1024 * 1024 else { throw PublicationFailure.invalidRequest }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        NotificationCenter.default.post(name: Notification.Name("PhotoRelayGroupReviewChanged"), object: nil)
        return archive
    }
}

enum GroupReviewEditing {
    static func merge(_ groups: [SuggestedPhotoGroup], selected: Set<String>) -> [SuggestedPhotoGroup] {
        let chosen = groups.filter { selected.contains($0.id) }
        guard chosen.count >= 2 else { return groups }
        let photos = chosen.flatMap(\.photos)
        let merged = SuggestedPhotoGroup(id: chosen[0].id, photos: photos,
            explanations: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, "Merged by you; no geographic inference.") }), title: chosen[0].title)
        var result = groups.filter { !selected.contains($0.id) }
        result.insert(merged, at: 0)
        return result
    }

    static func split(_ groups: [SuggestedPhotoGroup], selected: Set<String>) -> [SuggestedPhotoGroup] {
        let photos = groups.flatMap(\.photos).filter { selected.contains($0.id) }
        guard !photos.isEmpty else { return groups }
        var result = groups.compactMap { group -> SuggestedPhotoGroup? in
            var remaining = group
            remaining.photos.removeAll { selected.contains($0.id) }
            remaining.inferredLocationSources = [:]
            return remaining.photos.isEmpty ? nil : remaining
        }
        result.append(SuggestedPhotoGroup(id: UUID().uuidString, photos: photos,
            explanations: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, "Split into a new group by you.") })))
        return result
    }
}
