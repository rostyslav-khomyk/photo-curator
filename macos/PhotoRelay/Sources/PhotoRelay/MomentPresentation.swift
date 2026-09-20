import Foundation

enum MomentPresentation {
    static func narrative(_ moment: PhotoMoment, customTitle: String?, customDescription: String? = nil,
                          place: ResolvedPlace? = nil) -> MomentNarrative {
        let date = moment.start.formatted(date: .abbreviated, time: .omitted)
        let headline: String
        let state: MomentNarrative.State
        let provenance: [String]
        if let customTitle, !customTitle.isEmpty {
            headline = customTitle; state = .customized; provenance = ["user title"]
        } else if let reviewed = moment.reviewedGroupTitle, !reviewed.isEmpty {
            headline = reviewed; state = .customized; provenance = ["saved grouping title"]
        } else if moment.groupingKind == .unresolved {
            headline = "Needs review · \(date)"; state = .preparing; provenance = ["unresolved grouping", "date"]
        } else if let automatic = moment.narrative, !automatic.headline.isEmpty {
            headline = automatic.headline; state = .automatic; provenance = automatic.provenance
        } else if let place {
            let label = place.meaningfulLabel?.lowercased()
            let suffix = label == "home" ? "at home" : (label == "work" ? "at work" : "in \(place.friendlyName)")
            headline = "\(date) \(suffix)"; state = .preparing; provenance = ["resolved place", "date fallback"]
        } else {
            headline = date; state = .preparing; provenance = ["date"]
        }
        let story = customDescription ?? moment.narrative?.story
        return MomentNarrative(version: MomentNarrative.version, headline: headline, deck: nil, story: story,
            place: place?.friendlyName, date: date, confidence: state == .customized ? 1 : (state == .automatic ? 0.7 : 0.2),
            provenance: provenance, state: state)
    }

    static func title(_ moment: PhotoMoment, custom: String?, place: ResolvedPlace? = nil) -> String {
        narrative(moment, customTitle: custom, place: place).headline
    }

    static func status(_ moment: PhotoMoment, pending: Bool, userAuthored: Bool, place: ResolvedPlace? = nil) -> String {
        if userAuthored { return pending ? "Customized · preparing" : "✓ Customized" }
        if moment.groupingKind == .unresolved { return "Review needed" }
        if moment.narrative == nil { return "Title preparation is in progress…" }
        if pending { return "Preparing highlights…" }
        if let place = place { return place.friendlyName }
        if moment.groupingState == .preparing || moment.groupingState == nil { return "Preparing highlights…" }
        return ""
    }
}
