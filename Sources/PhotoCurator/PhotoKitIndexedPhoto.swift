import Foundation
import Photos

extension IndexedPhoto {
    /// Builds an indexed photo from a public PhotoKit asset without requesting pixels.
    static func fromPhotoKit(_ asset: PHAsset) -> IndexedPhoto {
        var photo = IndexedPhoto(
            id: asset.localIdentifier,
            created: asset.creationDate,
            modified: asset.modificationDate,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            favorite: asset.isFavorite,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            similarityCategory: asset.mediaSubtypes.contains(.photoScreenshot) ? .screenshots : .photos,
            burstIdentifier: asset.burstIdentifier
        )
        if #available(macOS 15, *) {
            photo.hasAdjustments = asset.hasAdjustments
            photo.adjustmentTimestamp = asset.adjustmentTimestamp
            photo.adjustmentFormatIdentifier = asset.adjustmentFormatIdentifier
        }
        if #available(macOS 26, *) {
            photo.addedDate = asset.addedDate
        }
        if #available(macOS 27, *) {
            photo.rating = asset.rating.rawValue
        }
        if let resource = PHAssetResource.assetResources(for: asset).first(where: {
            $0.type == .photo || $0.type == .fullSizePhoto
        }) {
            photo.sourceUTI = resource.uniformTypeIdentifier
        }
        return photo
    }
}
