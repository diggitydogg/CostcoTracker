import Foundation
import UIKit
import Combine

struct SavedReturnItem: Identifiable, Codable {

    let id: UUID

    let itemNumber: String
    let description: String
    let unitPrice: Double
    let quantity: Double

    let barcode: String
    let date: String
    let warehouse: String

    let dateAdded: Date

    var imageFilename: String?

    init(
        match: ReceiptMatch,
        imageFilename: String? = nil
    ) {

        self.id = UUID()

        self.itemNumber = match.itemNumber
        self.description = match.description
        self.unitPrice = match.unitPrice
        self.quantity = match.quantity

        self.barcode = match.barcode
        self.date = match.date
        self.warehouse = match.warehouse

        self.dateAdded = Date()

        self.imageFilename = imageFilename
    }

    var receiptMatch: ReceiptMatch {

        ReceiptMatch(
            itemNumber: itemNumber,
            description: description,
            unitPrice: unitPrice,
            quantity: quantity,
            barcode: barcode,
            date: date,
            warehouse: warehouse,
            withinWindow: false,
            qualifies: false,
            savings: 0
        )
    }

    var isOnlineOrder: Bool {
        warehouse.hasPrefix("Online Order")
    }

    var hasWarehouseReceiptBarcode: Bool {
        !isOnlineOrder && !barcode.isEmpty && !barcode.hasPrefix("WHSE_")
    }

    // Adapts this saved return to the ReturnPurchase shape expected by
    // ReturnReceiptCardSaver/ReturnReceiptCardView, which are shared with
    // Return Finder. The synthetic id is unused by either type.
    var asReturnPurchase: ReturnPurchase {

        ReturnPurchase(
            id: 0,
            itemNumber: itemNumber,
            description: description,
            unitPrice: unitPrice,
            quantity: quantity,
            receiptBarcode: barcode,
            date: date,
            warehouse: warehouse
        )
    }
}

@MainActor
final class SavedReturnStore: ObservableObject {

    static let shared = SavedReturnStore()

    @Published private(set) var items: [SavedReturnItem] = []

    private let storageKey = "costco_saved_returns"

    private init() {
        load()
    }

    // Re-reads saved returns from UserDefaults, e.g. after a backup restore
    // has replaced the stored data out from under this already-live instance.
    func reload() {
        load()
    }

    // MARK: - Add Return

    func add(
        match: ReceiptMatch,
        image: UIImage? = nil
    ) {

        // Same Costco item + same receipt = same saved return.
        if items.contains(where: {
            $0.itemNumber == match.itemNumber &&
            $0.barcode == match.barcode
        }) {
            return
        }

        var imageFilename: String? = nil

        if let image {
            imageFilename = saveImage(image)
        }

        let item = SavedReturnItem(
            match: match,
            imageFilename: imageFilename
        )

        items.insert(item, at: 0)

        save()
    }

    // MARK: - Remove Return

    func remove(_ item: SavedReturnItem) {

        if let filename = item.imageFilename {
            deleteImage(filename: filename)
        }

        items.removeAll {
            $0.id == item.id
        }

        save()
    }

    // MARK: - Clear All

    func clear() {

        for item in items {

            if let filename = item.imageFilename {
                deleteImage(filename: filename)
            }
        }

        items.removeAll()

        // Sweep the photos directory directly too, so no orphaned local
        // photo file can remain even if it wasn't referenced by any item.
        let directory = imageDirectory()

        if let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {

            for fileURL in contents {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        save()
    }

    // MARK: - Load Product Photo

    func image(for item: SavedReturnItem) -> UIImage? {

        guard let filename = item.imageFilename else {
            return nil
        }

        let url = imageDirectory()
            .appendingPathComponent(filename)

        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - UserDefaults

    private func save() {

        do {

            let data = try JSONEncoder().encode(items)

            UserDefaults.standard.set(
                data,
                forKey: storageKey
            )

        } catch {

            print(
                "COSTCO_RETURNS: Save error: \(error)"
            )
        }
    }

    private func load() {

        guard let data =
                UserDefaults.standard.data(
                    forKey: storageKey
                )
        else {
            return
        }

        do {

            items = try JSONDecoder().decode(
                [SavedReturnItem].self,
                from: data
            )

        } catch {

            print(
                "COSTCO_RETURNS: Load error: \(error)"
            )
        }
    }

    // MARK: - Product Photos

    private func imageDirectory() -> URL {

        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]

        let directory =
            base.appendingPathComponent(
                "ReturnProductPhotos",
                isDirectory: true
            )

        if !FileManager.default.fileExists(
            atPath: directory.path
        ) {

            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        return directory
    }

    private func saveImage(
        _ image: UIImage
    ) -> String? {

        guard let data =
                image.jpegData(
                    compressionQuality: 0.82
                )
        else {
            return nil
        }

        let filename =
            UUID().uuidString + ".jpg"

        let url =
            imageDirectory()
                .appendingPathComponent(filename)

        do {

            try data.write(
                to: url,
                options: .atomic
            )

            return filename

        } catch {

            print(
                "COSTCO_RETURNS: Image save error: \(error)"
            )

            return nil
        }
    }

    private func deleteImage(
        filename: String
    ) {

        let url =
            imageDirectory()
                .appendingPathComponent(filename)

        try? FileManager.default.removeItem(
            at: url
        )
    }
}
