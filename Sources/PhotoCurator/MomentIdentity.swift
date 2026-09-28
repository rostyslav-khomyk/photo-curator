import Foundation

struct MomentIdentityEntry: Codable, Equatable {
    let id: String
    let members: Set<String>
}

struct MomentIdentityResolution {
    let current: [MomentIdentityEntry]
    let retiredIDs: Set<String>
}

enum MomentIdentityResolver {
    /// Call only with complete snapshots of the same scope. Ambiguous split/merge titles
    /// stay with retired identities instead of silently moving to a different moment.
    static func resolve(previous: [MomentIdentityEntry], groups: [Set<String>], anchors: [String: Set<String>] = [:],
                        newID: () -> String = { UUID().uuidString }) throws -> MomentIdentityResolution {
        guard groups.allSatisfy({ !$0.isEmpty }),
              Set(previous.map(\.id)).count == previous.count,
              Set(groups.flatMap { $0 }).count == groups.reduce(0, { $0 + $1.count }),
              Set(previous.flatMap(\.members)).count == previous.reduce(0, { $0 + $1.members.count }),
              anchors.allSatisfy({ id, members in
                  !members.isEmpty && previous.first(where: { $0.id == id })?.members.isSuperset(of: members) == true
              }) else {
            throw PublicationFailure.invalidRequest
        }
        var anchoredGroup: [Int: String] = [:]
        for (id, members) in anchors {
            let matches = groups.indices.filter { members.isSubset(of: groups[$0]) }
            guard matches.count == 1, anchoredGroup[matches[0]] == nil else {
                throw PublicationFailure.conflictingOperation
            }
            anchoredGroup[matches[0]] = id
        }
        let overlaps = groups.map { group in previous.indices.filter { !previous[$0].members.isDisjoint(with: group) } }
        var used = Set<String>()
        let current = try groups.indices.map { index -> MomentIdentityEntry in
            let group = groups[index]
            var inherited = anchoredGroup[index]
            if inherited == nil, overlaps[index].count == 1, let old = overlaps[index].first,
               anchors[previous[old].id] == nil,
               overlaps.filter({ $0.contains(old) }).count == 1 {
                let shared = group.intersection(previous[old].members).count
                if Double(shared) / Double(group.count) >= 0.5,
                   Double(shared) / Double(previous[old].members.count) >= 0.5 {
                    inherited = previous[old].id
                }
            }
            let id = inherited ?? newID()
            guard !id.isEmpty, !used.contains(id), inherited != nil || !previous.contains(where: { $0.id == id }) else {
                throw PublicationFailure.invalidRequest
            }
            used.insert(id)
            return MomentIdentityEntry(id: id, members: group)
        }
        return MomentIdentityResolution(current: current, retiredIDs: Set(previous.map(\.id)).subtracting(used))
    }
}

/// Prototype persistence for one complete reconciliation scope; not wired to range previews.
/// Publication must not use this before full-scope reconciliation and legacy-title migration.
struct MomentIdentityArchive: Codable {
    var version = 1
    let scope: String
    let current: [MomentIdentityEntry]
    let retired: [MomentIdentityEntry]

    func reconcile(_ groups: [Set<String>], scope: String) throws -> Self {
        guard version == 1, self.scope == scope else { throw PublicationFailure.invalidRequest }
        let result = try MomentIdentityResolver.resolve(previous: current, groups: groups)
        return Self(scope: scope, current: result.current,
                    retired: retired + current.filter { result.retiredIDs.contains($0.id) })
    }
}

struct MomentIdentityStore {
    let url: URL
    func reconcile(_ groups: [Set<String>], scope: String) throws -> MomentIdentityArchive {
        let lock = try PublicationJournalLock(journal: url)
        defer { withExtendedLifetime(lock) {} }
        let previous: MomentIdentityArchive
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1024 * 1024 else {
                throw PublicationFailure.corruptJournal
            }
            previous = try JSONDecoder().decode(MomentIdentityArchive.self, from: Data(contentsOf: url))
        } else { previous = MomentIdentityArchive(scope: scope, current: [], retired: []) }
        let updated = try previous.reconcile(groups, scope: scope)
        let data = try JSONEncoder().encode(updated)
        guard data.count <= 16 * 1024 * 1024 else { throw PublicationFailure.invalidRequest }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return updated
    }
}
