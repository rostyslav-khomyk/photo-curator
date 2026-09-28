import Foundation
import Photos

enum PhotoKitAssetEditFailure: LocalizedError {
    case permissionDenied
    case assetUnavailable
    case editNotAllowed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Full Photos access is required to make this change."
        case .assetUnavailable: "This photo is no longer available in your Photos library."
        case .editNotAllowed: "Photos does not allow this item to be changed."
        }
    }
}

struct PhotoKitAssetEditor: Sendable {
    static let shared = PhotoKitAssetEditor()

    func setFavorite(_ favorite: Bool, assetID: String) async throws {
        let asset = try editableAsset(assetID)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = favorite
        }
    }

    func moveToRecentlyDeleted(assetID: String) async throws {
        let asset = try editableAsset(assetID)
        guard asset.canPerform(.delete) else { throw PhotoKitAssetEditFailure.editNotAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }

    private func editableAsset(_ id: String) throws -> PHAsset {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw PhotoKitAssetEditFailure.permissionDenied
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotoKitAssetEditFailure.assetUnavailable
        }
        return asset
    }
}
