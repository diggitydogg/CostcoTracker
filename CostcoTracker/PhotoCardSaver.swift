
import SwiftUI
import Photos

@MainActor
enum PhotoCardSaver {

    static let albumName = "Costco Price Matches"

    // MARK: - Render a card as an image

    static func renderCard(
        match: ReceiptMatch,
        newPrice: Double
    ) -> UIImage? {

        let card = SavedMatchPhotoView(
            match: match,
            newPrice: newPrice
        )

        let renderer = ImageRenderer(content: card)

        renderer.scale = 2.0

        return renderer.uiImage
    }

    // MARK: - Save one card

    // This preserves the existing Save to Photos button.

    static func save(
        match: ReceiptMatch,
        newPrice: Double,
        completion: @escaping (Bool) -> Void
    ) {

        saveAll(
            matches: [match],
            newPrice: newPrice
        ) { saved, total in

            completion(saved == 1 && total == 1)
        }
    }

    // MARK: - Save multiple cards

    static func saveAll(
        matches: [ReceiptMatch],
        newPrice: Double,
        completion: @escaping (Int, Int) -> Void
    ) {

        let total = matches.count

        guard total > 0 else {
            completion(0, 0)
            return
        }

        // Request access to organize a custom album.

        PHPhotoLibrary.requestAuthorization(
            for: .readWrite
        ) { status in

            DispatchQueue.main.async {

                guard status == .authorized else {

                    print(
                        "COSTCO_PHOTO: Full photo access required."
                    )

                    completion(0, total)
                    return
                }

                // Render images on the main thread.

                let images = matches.compactMap { match in

                    renderCard(
                        match: match,
                        newPrice: newPrice
                    )
                }

                guard images.count == total else {

                    print(
                        "COSTCO_PHOTO: Some cards could not render."
                    )

                    completion(0, total)
                    return
                }

                // Find the album if it already exists.

                let options = PHFetchOptions()

                options.predicate = NSPredicate(
                    format: "title = %@",
                    albumName
                )

                let albums = PHAssetCollection
                    .fetchAssetCollections(
                        with: .album,
                        subtype: .any,
                        options: options
                    )

                let existingAlbum = albums.firstObject
                
                let title = albumName

                // MARK: - Save to Photos

                PHPhotoLibrary.shared().performChanges({

                    let albumRequest: PHAssetCollectionChangeRequest

                    if let existingAlbum = existingAlbum {

                        // Reuse the existing album.

                        guard let request =
                            PHAssetCollectionChangeRequest(
                                for: existingAlbum
                            )
                        else {
                            return
                        }

                        albumRequest = request

                    } else {

                        // Create the album only when needed.

                        albumRequest =
                            PHAssetCollectionChangeRequest
                            .creationRequestForAssetCollection(
                                withTitle: title
                            )
                    }

                    // Create each photo in the requested order.

                    var placeholders: [PHObjectPlaceholder] = []

                    for image in images {

                        let request =
                            PHAssetChangeRequest
                            .creationRequestForAsset(
                                from: image
                            )

                        if let placeholder =
                            request.placeholderForCreatedAsset {

                            placeholders.append(placeholder)
                        }
                    }

                    // Add the newly created photos to the album.

                    albumRequest.addAssets(
                        placeholders as NSArray
                    )

                }, completionHandler: { success, error in

                    DispatchQueue.main.async {

                        if let error = error {

                            print(
                                "COSTCO_PHOTO: \(error.localizedDescription)"
                            )
                        }

                        if success && error == nil {

                            completion(total, total)

                        } else {

                            completion(0, total)
                        }
                    }
                })
            }
        }
    }
}
