
import Foundation
import SwiftUI
import Combine

// MARK: - One Saved Queue Item

struct QueuedPriceMatch: Identifiable, Codable {

    let id: UUID

    let itemNumber: String
    let description: String

    let unitPrice: Double
    let newPrice: Double
    let quantity: Double

    let barcode: String
    let date: String
    let warehouse: String

    let withinWindow: Bool
    let qualifies: Bool
    let savings: Double

    let dateAdded: Date

    // Create a queue item from a database result.

    init(match: ReceiptMatch, newPrice: Double) {

        self.id = UUID()

        self.itemNumber = match.itemNumber
        self.description = match.description

        self.unitPrice = match.unitPrice
        self.newPrice = newPrice
        self.quantity = match.quantity

        self.barcode = match.barcode
        self.date = match.date
        self.warehouse = match.warehouse

        self.withinWindow = match.withinWindow
        self.qualifies = match.qualifies
        self.savings = match.savings

        self.dateAdded = Date()
    }

    // Convert back to ReceiptMatch for our photo renderer.

    var receiptMatch: ReceiptMatch {

        ReceiptMatch(
            itemNumber: itemNumber,
            description: description,
            unitPrice: unitPrice,
            quantity: quantity,
            barcode: barcode,
            date: date,
            warehouse: warehouse,
            withinWindow: withinWindow,
            qualifies: qualifies,
            savings: savings
        )
    }

    var isOnlineOrder: Bool {
        warehouse.hasPrefix("Online Order")
    }

    var hasWarehouseReceiptBarcode: Bool {
        !isOnlineOrder && !barcode.isEmpty && !barcode.hasPrefix("WHSE_")
    }
}

// MARK: - Queue Manager

@MainActor
final class PriceMatchQueue: ObservableObject {

    static let shared = PriceMatchQueue()

    @Published private(set) var items: [QueuedPriceMatch] = []

    private let storageKey = "costco_price_match_queue"

    private init() {
        loadQueue()
    }

    // Re-reads the queue from UserDefaults, e.g. after a backup restore
    // has replaced the stored data out from under this already-live instance.
    func reload() {
        loadQueue()
    }

    // MARK: - Add Matches

    func add(matches: [ReceiptMatch], newPrice: Double) {

        for match in matches {

            // Only collect purchases with potential savings.

            guard match.savings > 0 else {
                continue
            }

            let newItem = QueuedPriceMatch(
                match: match,
                newPrice: newPrice
            )

            // Prevent duplicate entries for the same
            // purchased item on the same receipt.

            if let index = items.firstIndex(where: {

                $0.barcode == match.barcode &&
                $0.itemNumber == match.itemNumber

            }) {

                // Update the price if this item was
                // scanned again at a different shelf price.

                items[index] = newItem

            } else {

                items.append(newItem)
            }
        }

        saveQueue()
    }

    // MARK: - Remove One Item

    func remove(_ item: QueuedPriceMatch) {

        items.removeAll {
            $0.id == item.id
        }

        saveQueue()
    }

    // MARK: - Clear Everything

    func clear() {

        items.removeAll()

        saveQueue()
    }

    // MARK: - Total Potential Savings

    var totalSavings: Double {

        items.reduce(0) {
            $0 + $1.savings
        }
    }

    // MARK: - Save Queue to Device

    private func saveQueue() {

        do {

            let data = try JSONEncoder().encode(items)

            UserDefaults.standard.set(
                data,
                forKey: storageKey
            )

        } catch {

            print(
                "COSTCO_QUEUE: Save error: \(error)"
            )
        }
    }

    // MARK: - Load Queue from Device

    private func loadQueue() {

        guard let data = UserDefaults.standard.data(
            forKey: storageKey
        ) else {
            return
        }

        do {

            items = try JSONDecoder().decode(
                [QueuedPriceMatch].self,
                from: data
            )

        } catch {

            print(
                "COSTCO_QUEUE: Load error: \(error)"
            )
        }
    }
}
