import Foundation

enum MomentGroupingInterpretation {
    static func describe(moment: PhotoMoment, place: ResolvedPlace?) -> String {
        var sentences: [String] = []

        // 1. Photo count, favorites, and time duration
        let photoCount = moment.photos.count
        let favCount = moment.favorites
        let photoText = "\(photoCount) photo" + (photoCount == 1 ? "" : "s")
        let favText = favCount > 0 ? " (including \(favCount) favorite" + (favCount == 1 ? "" : "s") + ")" : ""

        let durationSeconds = moment.end.timeIntervalSince(moment.start)
        let timeSpanText: String
        if durationSeconds < 60 {
            timeSpanText = "taken around the same time"
        } else if durationSeconds < 3600 {
            let minutes = max(1, Int(round(durationSeconds / 60)))
            timeSpanText = "captured over \(minutes) minute" + (minutes == 1 ? "" : "s")
        } else {
            let hours = String(format: "%.1f", durationSeconds / 3600).replacingOccurrences(of: ".0", with: "")
            timeSpanText = "captured across \(hours) hours"
        }

        let dateStr = moment.start.formatted(date: .abbreviated, time: .omitted)

        // 2. Location & Extrapolation statement
        let gpsPhotos = moment.photos.filter { $0.latitude != nil && $0.longitude != nil }
        let locationSentence: String
        if let place = place {
            if place.isExtrapolated {
                locationSentence = "Location estimated as \(place.friendlyName) based on photos taken nearby on the same day."
            } else if gpsPhotos.count == moment.photos.count {
                locationSentence = "Recorded GPS coordinates confirm location in \(place.friendlyName) for all photos."
            } else if !gpsPhotos.isEmpty {
                let gpsWord = gpsPhotos.count == 1 ? "photo" : "photos"
                locationSentence = "Recorded GPS confirms location in \(place.friendlyName) for \(gpsPhotos.count) \(gpsWord), with the rest taken in the same sequence."
            } else {
                locationSentence = "Location identified as \(place.friendlyName)."
            }
        } else if !gpsPhotos.isEmpty {
            locationSentence = "Recorded GPS confirms a shared location across photos."
        } else {
            locationSentence = "Grouped by capture timing and consistent scene setting."
        }

        sentences.append("\(photoText)\(favText) \(timeSpanText) on \(dateStr). \(locationSentence)")

        // 3. Visual Activity / Scene clues
        if let title = moment.narrative?.headline,
           !title.isEmpty,
           title != dateStr,
           !title.contains(dateStr) {
            sentences.append("Visual clues highlight \(title.lowercased()).")
        }

        // 4. Session continuity & curation notes
        if moment.continuityReason != nil {
            sentences.append("Photos across brief pauses were combined into this single moment based on visual continuity and location match.")
        } else if moment.reviewedGroupTitle != nil {
            sentences.append("This moment reflects your custom title and curated grouping.")
        } else {
            sentences.append("Continuous camera session with consistent lighting. Near-duplicate shots and burst takes are organized as alternative angles so your best photos stand out.")
        }

        return sentences.joined(separator: " ")
    }
}
