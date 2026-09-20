import Foundation

struct MomentMultiSelection {
    var ids: Set<String> = []
    var anchor: String?

    mutating func click(_ id: String, ordered: [String], range: Bool) {
        guard let end = ordered.firstIndex(of: id) else { return }
        if range, let anchor, let start = ordered.firstIndex(of: anchor) {
            ids.formUnion(ordered[min(start, end)...max(start, end)])
        } else {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        }
    }
}
