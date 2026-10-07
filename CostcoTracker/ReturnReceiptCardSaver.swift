import SwiftUI
import Photos

// Separate from PhotoCardSaver: the price-match album and code remain unchanged.
@MainActor
enum ReturnReceiptCardSaver {
    static let albumName = "Costco Returns"

    static func save(purchase: ReturnPurchase, completion: @escaping (Bool) -> Void) {
        let renderer = ImageRenderer(content: ReturnReceiptCardView(purchase: purchase))
        renderer.scale = 2.0

        guard let image = renderer.uiImage else {
            print("COSTCO_RETURN_PHOTO: Could not render receipt card")
            completion(false)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    print("COSTCO_RETURN_PHOTO: Full Photos access is needed to find and reuse the Costco Returns album")
                    completion(false)
                    return
                }

                let options = PHFetchOptions()
                options.predicate = NSPredicate(format: "title = %@", albumName)
                let existingAlbum = PHAssetCollection.fetchAssetCollections(
                    with: .album,
                    subtype: .any,
                    options: options
                ).firstObject
                let title = albumName

                PHPhotoLibrary.shared().performChanges({
                    let albumRequest: PHAssetCollectionChangeRequest
                    if let existingAlbum = existingAlbum {
                        guard let request = PHAssetCollectionChangeRequest(for: existingAlbum) else {
                            return
                        }
                        albumRequest = request
                    } else {
                        albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                            withTitle: title
                        )
                    }

                    let assetRequest = PHAssetChangeRequest.creationRequestForAsset(from: image)
                    if let placeholder = assetRequest.placeholderForCreatedAsset {
                        albumRequest.addAssets([placeholder] as NSArray)
                    }
                }, completionHandler: { success, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            print("COSTCO_RETURN_PHOTO: \(error.localizedDescription)")
                        }
                        completion(success && error == nil)
                    }
                })
            }
        }
    }
}
