import Photos

enum SimilarityCategory: String, CaseIterable, Codable, Identifiable {
    case photos, selfies, portraits, panoramas, livePhotos, raw, bursts, animated, screenshots
    var id: Self { self }
    var title: String {
        switch self {
        case .photos: "Other Photos"
        case .selfies: "Selfies"
        case .portraits: "Portrait"
        case .panoramas: "Panoramas"
        case .livePhotos: "Live Photos"
        case .raw: "RAW"
        case .bursts: "Bursts"
        case .animated: "Animated"
        case .screenshots: "Screenshots"
        }
    }

    var preferenceKey: String { "curator.similarity.category.\(CuratorVisionAnalyzer.version).\(rawValue)" }
    static func savedThresholds() -> [Self: Float] {
        Dictionary(uniqueKeysWithValues: allCases.map { category in
            let value = (UserDefaults.standard.object(forKey: category.preferenceKey) as? NSNumber)?.floatValue ?? 0.01
            return (category, value.isFinite && value >= 0 ? value : 0.01)
        })
    }
}

enum PhotoKitSimilarityCategories {
    // Resolve current public metadata for cached assets too; no migration or reanalysis needed.
    static func classify(_ photos: [IndexedPhoto], range: DateInterval) -> [IndexedPhoto] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@ AND mediaType == %d",
                                        range.start as NSDate, range.end as NSDate, PHAssetMediaType.image.rawValue)
        options.includeHiddenAssets = false
        var categories: [String: SimilarityCategory] = [:]
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            categories[asset.localIdentifier] = .photos
        }
        // Overlapping Photos groups need a deterministic primary category. Later wins.
        let groups: [(PHAssetCollectionSubtype, SimilarityCategory)] = [
            (.smartAlbumLivePhotos, .livePhotos), (.smartAlbumRAW, .raw),
            (.smartAlbumBursts, .bursts), (.smartAlbumAnimated, .animated),
            (.smartAlbumPanoramas, .panoramas), (.smartAlbumDepthEffect, .portraits),
            (.smartAlbumSelfPortraits, .selfies), (.smartAlbumScreenshots, .screenshots)
        ]
        for (subtype, category) in groups {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).enumerateObjects { album, _, _ in
                PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
                    categories[asset.localIdentifier] = category
                }
            }
        }
        // Also use the explicit screenshot flag, even if a smart album is unavailable.
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoScreenshot) { categories[asset.localIdentifier] = .screenshots }
        }
        let unclassified = photos.filter { categories[$0.id] == nil }
        if !unclassified.isEmpty {
            let direct = PHAsset.fetchAssets(withLocalIdentifiers: unclassified.map(\.id), options: nil)
            direct.enumerateObjects { asset, _, _ in
                if !asset.isHidden {
                    categories[asset.localIdentifier] = asset.mediaSubtypes.contains(.photoScreenshot) ? .screenshots : .photos
                }
            }
        }
        return photos.compactMap { photo in
            guard let category = categories[photo.id] else { return nil }
            var copy = photo
            copy.similarityCategory = category
            return copy
        }
    }
}
