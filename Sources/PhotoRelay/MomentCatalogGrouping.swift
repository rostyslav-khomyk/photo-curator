import Foundation
import CryptoKit

/// Apply explicit group decisions over the full indexed scope, never just a UI page.
enum MomentCatalogGrouping {
    static func build(_ photos: [IndexedPhoto], reviews: GroupReviewArchive,
                      protection: MomentGroupingProtection = .init()) -> [PhotoMoment] {
        let available = Dictionary(uniqueKeysWithValues: photos.filter { $0.created != nil }.map { ($0.id, $0) })
        var assigned = Set<String>()
        var output: [PhotoMoment] = []
        for review in reviews.groups {
            let members = review.members.compactMap { available[$0] }.sorted {
                $0.created == $1.created ? $0.id < $1.id : $0.created! < $1.created!
            }
            guard let first = members.first, let last = members.last else { continue }
            assigned.formUnion(members.map(\.id))
            output.append(PhotoMoment(id: review.id, start: first.created!, end: last.created!,
                                      photos: members, reviewedGroupTitle: review.title.isEmpty ? nil : review.title,
                                      groupingReason: "Saved group membership chosen by you.", groupingState: .reviewed))
        }
        // Explicit split/merge edits win over the membership captured when naming a Moment.
        let reviewedIDs = Set(reviews.groups.map(\.id))
        for id in protection.members.keys.sorted() where !reviewedIDs.contains(id) {
            let members = protection.members[id]!.subtracting(assigned).compactMap { available[$0] }.sorted {
                $0.created == $1.created ? $0.id < $1.id : $0.created! < $1.created!
            }
            guard let first = members.first, let last = members.last else { continue }
            assigned.formUnion(members.map(\.id))
            output.append(PhotoMoment(id: id, start: first.created!, end: last.created!, photos: members,
                groupingReason: "Membership kept with your saved title or description.", groupingState: .reviewed))
        }
        for original in MomentGrouping.group(photos) {
            let remaining = original.photos.filter { !assigned.contains($0.id) }
            guard !remaining.isEmpty else { continue }
            if remaining.count == original.photos.count { output.append(original); continue }
            for residual in MomentGrouping.group(remaining) {
                // Do not silently attach an old full-group title to a partial remainder.
                let fingerprint = residual.photos.map(\.id).sorted().joined(separator: "|")
                let hash = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
                output.append(PhotoMoment(id: "remainder-" + hash, start: residual.start, end: residual.end,
                                          photos: residual.photos))
            }
        }
        return output.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
    }
}
