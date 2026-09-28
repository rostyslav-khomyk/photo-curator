import Foundation
import Photos
import UniformTypeIdentifiers

/// Read-only PhotoKit metadata audit for unlocated-history qualification.
/// Runs inside Photo Curator so it reuses the app's TCC Photos grant.
/// Never requests image downloads, mutations, or cloud inference.
enum HistoricalMetadataAudit {
    /// UTC start of 2007-01-01; matches the owner historical benchmark window.
    static let historicalCutoff = Date(timeIntervalSince1970: 1_167_609_600)

    struct Report {
        var authorizationStatus: String
        var photos: Int
        var located: Int
        var favorites: Int
        var adjustmentResources: Int
        var hasAdjustments: Int
        var withAdjustmentTimestamp: Int
        var withAddedDate: Int
        var addedDateDiffersFromCapture: Int
        var ratedPhotos: Int
        var ratingCounts: [String: Int]
        var mediaSubtypeCounts: [String: Int]
        var burstPhotos: Int
        var contentTypeCounts: [String: Int]
        var sourceTypes: [String: Int]
        var fileExtensions: [String: Int]
        var albumCoveredPhotos: Int
        var outsideCuratorCoveredPhotos: Int
        var namedAlbums: Int
        var albumsWithLocationNames: Int
        var albumsWithApproximateLocation: Int
        var photosWithCaption: Int
        var photosWithKeywords: Int
        var photosWithOriginalFilename: Int
        var albumStoryCandidates: [[String: Any]]
        var albums: [[String: Any]]
        var extendedMetadata: [[String: Any]]

        var jsonObject: [String: Any] {
            [
                "authorizationStatus": authorizationStatus,
                "photos": photos,
                "located": located,
                "favorites": favorites,
                "adjustmentResources": adjustmentResources,
                "hasAdjustments": hasAdjustments,
                "withAdjustmentTimestamp": withAdjustmentTimestamp,
                "withAddedDate": withAddedDate,
                "addedDateDiffersFromCapture": addedDateDiffersFromCapture,
                "ratedPhotos": ratedPhotos,
                "ratingCounts": ratingCounts,
                "mediaSubtypeCounts": mediaSubtypeCounts,
                "burstPhotos": burstPhotos,
                "contentTypeCounts": contentTypeCounts,
                "sourceTypes": sourceTypes,
                "fileExtensions": fileExtensions,
                "albumCoveredPhotos": albumCoveredPhotos,
                "outsideCuratorCoveredPhotos": outsideCuratorCoveredPhotos,
                "namedAlbums": namedAlbums,
                "albumsWithLocationNames": albumsWithLocationNames,
                "albumsWithApproximateLocation": albumsWithApproximateLocation,
                "photosWithCaption": photosWithCaption,
                "photosWithKeywords": photosWithKeywords,
                "photosWithOriginalFilename": photosWithOriginalFilename,
                "albumStoryCandidates": albumStoryCandidates,
                "albums": albums,
                "extendedMetadata": extendedMetadata,
                "privacy": "Private owner audit. Contains album titles, captions, keywords, and asset identifiers. Do not share or commit."
            ]
        }
    }

    enum AuditError: LocalizedError {
        case unauthorized(PHAuthorizationStatus)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized(let status):
                return "PhotoKit access is \(authorizationLabel(status)). Open Photo Curator after allowing Photos access in System Settings > Privacy & Security > Photos."
            case .writeFailed(let detail):
                return "Could not write the private audit report (\(detail))."
            }
        }
    }

    static func authorizationLabel(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    /// Collects album membership and public PhotoKit metadata for pre-2007 photos.
    static func collect(cutoff: Date = historicalCutoff) throws -> Report {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else { throw AuditError.unauthorized(status) }

        let options = PHFetchOptions()
        if #available(macOS 27, *) { options.prefetchAssetExtendedMetadata = true }
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate < %@",
            PHAssetMediaType.image.rawValue,
            cutoff as NSDate
        )
        let assets = PHAsset.fetchAssets(with: options)
        var historicalIDs = Set<String>()
        var extensions: [String: Int] = [:]
        var sourceTypes: [String: Int] = [:]
        var mediaSubtypeCounts: [String: Int] = [:]
        var contentTypeCounts: [String: Int] = [:]
        var ratingCounts: [String: Int] = [:]
        var located = 0
        var favorites = 0
        var adjusted = 0
        var hasAdjustments = 0
        var withAdjustmentTimestamp = 0
        var withAddedDate = 0
        var addedDateDiffersFromCapture = 0
        var ratedPhotos = 0
        var burstPhotos = 0
        var photosWithCaption = 0
        var photosWithKeywords = 0
        var photosWithOriginalFilename = 0
        var extended: [[String: Any]] = []

        assets.enumerateObjects { asset, _, _ in
            historicalIDs.insert(asset.localIdentifier)
            if asset.location != nil { located += 1 }
            if asset.isFavorite { favorites += 1 }
            sourceTypes[String(asset.sourceType.rawValue), default: 0] += 1
            for label in mediaSubtypeLabels(asset.mediaSubtypes) {
                mediaSubtypeCounts[label, default: 0] += 1
            }
            if asset.burstIdentifier != nil { burstPhotos += 1 }

            var row: [String: Any] = [
                "assetID": asset.localIdentifier,
                "created": asset.creationDate?.timeIntervalSince1970 ?? NSNull(),
                "modified": asset.modificationDate?.timeIntervalSince1970 ?? NSNull(),
                "width": asset.pixelWidth,
                "height": asset.pixelHeight,
                "favorite": asset.isFavorite,
                "mediaSubtypes": asset.mediaSubtypes.rawValue,
                "burstIdentifier": asset.burstIdentifier ?? ""
            ]

            if #available(macOS 26, *) {
                row["contentType"] = asset.contentType.identifier
                contentTypeCounts[asset.contentType.identifier, default: 0] += 1
                if let added = asset.addedDate {
                    withAddedDate += 1
                    row["added"] = added.timeIntervalSince1970
                    if let created = asset.creationDate,
                       abs(added.timeIntervalSince(created)) >= 24 * 3600 {
                        addedDateDiffersFromCapture += 1
                    }
                }
            }

            if #available(macOS 15, *) {
                row["hasAdjustments"] = asset.hasAdjustments
                row["adjustmentsState"] = asset.adjustmentsState.rawValue
                row["adjustmentFormatIdentifier"] = asset.adjustmentFormatIdentifier ?? ""
                if asset.hasAdjustments { hasAdjustments += 1 }
                if let timestamp = asset.adjustmentTimestamp {
                    withAdjustmentTimestamp += 1
                    row["adjustmentTimestamp"] = timestamp.timeIntervalSince1970
                }
            }

            if #available(macOS 27, *) {
                let rating = asset.rating
                row["rating"] = rating.rawValue
                if rating != .unset {
                    ratedPhotos += 1
                    ratingCounts[String(rating.rawValue), default: 0] += 1
                }
                row["originalResourceChoice"] = asset.originalResourceChoice.rawValue
                let metadata = asset.extendedMetadata
                let caption = (metadata.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let keywords = metadata.keywords.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                let filename = (metadata.originalFilename ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !caption.isEmpty { photosWithCaption += 1 }
                if !keywords.isEmpty { photosWithKeywords += 1 }
                if !filename.isEmpty { photosWithOriginalFilename += 1 }
                row["caption"] = caption
                row["keywords"] = keywords
                row["originalFilename"] = filename
            }

            extended.append(row)

            let resources = PHAssetResource.assetResources(for: asset)
            if resources.contains(where: { $0.type == .adjustmentData }) { adjusted += 1 }
            if let resource = resources.first(where: { $0.type == .photo }) {
                let name: String
                if #available(macOS 27, *) { name = resource.filename ?? "" }
                else { name = resource.originalFilename }
                let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                if !ext.isEmpty { extensions[ext, default: 0] += 1 }
            }
        }

        var rows: [[String: Any]] = []
        var covered = Set<String>()
        var outsideCurator = Set<String>()
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { album, _, _ in
            autoreleasepool {
                let members = PHAsset.fetchAssets(in: album, options: options)
                guard members.count > 0 else { return }
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
                let underCurator = ancestors.contains {
                    $0.caseInsensitiveCompare("Photo Curator") == .orderedSame
                }
                members.enumerateObjects { asset, _, _ in
                    guard historicalIDs.contains(asset.localIdentifier) else { return }
                    covered.insert(asset.localIdentifier)
                    if !underCurator { outsideCurator.insert(asset.localIdentifier) }
                }
                rows.append([
                    "title": album.localizedTitle ?? "",
                    "historicalPhotos": members.count,
                    "folderNames": ancestors,
                    "underPhotoCurator": underCurator,
                    "locationNames": album.localizedLocationNames,
                    "hasApproximateLocation": album.approximateLocation != nil
                ])
            }
        }

        let sortedAlbums = rows.sorted {
            ($0["historicalPhotos"] as? Int ?? 0) > ($1["historicalPhotos"] as? Int ?? 0)
        }
        let namedAlbums = sortedAlbums.filter { row in
            let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !title.isEmpty
        }.count
        let albumsWithLocationNames = sortedAlbums.filter {
            !((($0["locationNames"] as? [String]) ?? []).filter { !$0.isEmpty }.isEmpty)
        }.count
        let albumsWithApproximateLocation = sortedAlbums.filter {
            ($0["hasApproximateLocation"] as? Bool) == true
        }.count
        let review = try? OwnerAlbumStoryReviewStore.load()
        let candidates = UnlocatedAlbumStoryCandidates.propose(from: sortedAlbums).map { candidate -> [String: Any] in
            var object = candidate.jsonObject
            if let kind = review?.kind(forAlbumTitle: candidate.title) {
                object["ownerKind"] = kind.rawValue
                object["ownerShipsAsStory"] = kind.shipsAsStory
            }
            return object
        }

        return Report(
            authorizationStatus: authorizationLabel(status),
            photos: assets.count,
            located: located,
            favorites: favorites,
            adjustmentResources: adjusted,
            hasAdjustments: hasAdjustments,
            withAdjustmentTimestamp: withAdjustmentTimestamp,
            withAddedDate: withAddedDate,
            addedDateDiffersFromCapture: addedDateDiffersFromCapture,
            ratedPhotos: ratedPhotos,
            ratingCounts: ratingCounts,
            mediaSubtypeCounts: mediaSubtypeCounts,
            burstPhotos: burstPhotos,
            contentTypeCounts: contentTypeCounts,
            sourceTypes: sourceTypes,
            fileExtensions: extensions,
            albumCoveredPhotos: covered.count,
            outsideCuratorCoveredPhotos: outsideCurator.count,
            namedAlbums: namedAlbums,
            albumsWithLocationNames: albumsWithLocationNames,
            albumsWithApproximateLocation: albumsWithApproximateLocation,
            photosWithCaption: photosWithCaption,
            photosWithKeywords: photosWithKeywords,
            photosWithOriginalFilename: photosWithOriginalFilename,
            albumStoryCandidates: candidates,
            albums: sortedAlbums,
            extendedMetadata: extended
        )
    }

    static func write(_ report: Report, to destination: URL, fileManager: FileManager = .default) throws {
        let data = try JSONSerialization.data(
            withJSONObject: report.jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        do {
            try data.write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            throw AuditError.writeFailed(error.localizedDescription)
        }
    }

    static func export(to destination: URL, cutoff: Date = historicalCutoff) throws -> Report {
        let report = try collect(cutoff: cutoff)
        try write(report, to: destination)
        return report
    }

    private static func mediaSubtypeLabels(_ subtypes: PHAssetMediaSubtype) -> [String] {
        var labels: [String] = []
        if subtypes.contains(.photoScreenshot) { labels.append("screenshot") }
        if subtypes.contains(.photoPanorama) { labels.append("panorama") }
        if subtypes.contains(.photoHDR) { labels.append("hdr") }
        if subtypes.contains(.photoLive) { labels.append("live") }
        if subtypes.contains(.photoDepthEffect) { labels.append("depthEffect") }
        if labels.isEmpty { labels.append("none") }
        return labels
    }
}

/// Deterministic, review-gated proposals from user album evidence. Not shipping Stories.
enum UnlocatedAlbumStoryCandidates {
    struct Candidate: Equatable {
        var title: String
        var folderNames: [String]
        var historicalPhotos: Int
        var hasAlbumLocation: Bool
        var score: Double
        var reason: String

        var jsonObject: [String: Any] {
            [
                "title": title,
                "folderNames": folderNames,
                "historicalPhotos": historicalPhotos,
                "hasAlbumLocation": hasAlbumLocation,
                "score": score,
                "reason": reason,
                "provenance": "userAlbum",
                "shipping": false
            ]
        }
    }

    static func propose(from albums: [[String: Any]], minimumPhotos: Int = 40) -> [Candidate] {
        albums.compactMap { row -> Candidate? in
            let title = ((row["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            guard (row["underPhotoCurator"] as? Bool) != true else { return nil }
            let count = row["historicalPhotos"] as? Int ?? 0
            guard count >= minimumPhotos else { return nil }
            let folders = ((row["folderNames"] as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let locations = ((row["locationNames"] as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let hasLocation = !locations.isEmpty || (row["hasApproximateLocation"] as? Bool) == true
            let outline = AlbumOutlinePatterns.scoreAdjustment(title: title, folderNames: folders)
            if AlbumOutlinePatterns.signals(title: title, folderNames: folders).contains(.technicalSkip) {
                return nil
            }
            var score = min(1.0, Double(count) / 400.0)
            var reasons: [String] = ["\(count) historical photos"]
            if hasLocation {
                score += 0.25
                reasons.append("album location metadata")
            }
            score += outline.delta
            reasons.append(contentsOf: outline.reasons)
            if folders.count >= 2, !outline.reasons.contains("nested under place folder") {
                score += 0.05
                reasons.append("nested folders")
            }
            guard score >= 0.2 else { return nil }
            return Candidate(
                title: title,
                folderNames: folders,
                historicalPhotos: count,
                hasAlbumLocation: hasLocation,
                score: min(1.0, max(0, score)),
                reason: reasons.joined(separator: "; ")
            )
        }
        .sorted {
            if $0.score == $1.score { return $0.historicalPhotos > $1.historicalPhotos }
            return $0.score > $1.score
        }
    }
}
