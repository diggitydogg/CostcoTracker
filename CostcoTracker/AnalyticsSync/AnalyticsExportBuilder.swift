import Foundation

// MARK: - Source rows → Analytics Export V1
//
// Pure mapping (no I/O). Rules, matching ANALYTICS_DATA_CONTRACT.md:
// - money: integer cents, round-half-away-from-zero of (dollars × 100)
// - item lineTotalCents = round(unit_price × quantity × 100) (the stored net
//   line total); unitPriceCents only when unit_price is a whole number of cents
// - dates: real YYYY-MM-DD calendar dates, otherwise null
// - text: null when missing or blank (item descriptions are kept verbatim)
// - quantities may be fractional
// - sourcePurchaseId is always null (the database never knows the purchase)
// - raw barcodes / WHSE_ keys / order keys appear only inside ID derivation
// Rows that cannot be represented validly are excluded and counted by reason;
// nothing is guessed or coerced into a value the source did not record.

nonisolated enum AnalyticsExportBuilder {

    static func build(_ snapshot: SourceSnapshot, ids: AnalyticsIDDeriver) -> AnalyticsDataset {
        var exclusions: [AnalyticsExclusionReason: Int] = [:]
        func exclude(_ reason: AnalyticsExclusionReason, _ count: Int = 1) {
            exclusions[reason, default: 0] += count
        }

        // Receipts
        var receiptsByBarcode: [String: AnalyticsReceipt] = [:]
        for row in snapshot.receipts {
            guard let barcode = row.barcode, !isBlank(barcode) else {
                exclude(.receiptMissingKey)
                continue
            }
            let online = (row.warehouse ?? "").hasPrefix("Online Order")
            let kind: AnalyticsIdentifierKind =
                online ? .onlineOrderKey : barcode.hasPrefix("WHSE_") ? .synthesizedWarehouseKey : .transactionBarcode
            receiptsByBarcode[barcode] = AnalyticsReceipt(
                id: ids.receiptID(barcode: barcode),
                sourceType: online ? .online : .warehouse,
                identifierKind: kind,
                purchaseDate: calendarDate(row.date),
                warehouse: text(row.warehouse)
            )
        }

        // Items: occurrence is counted over every row of the receipt with the
        // same item number (by rowid), before validity filtering, so a row
        // becoming valid later never renumbers its siblings.
        var itemsByBarcode: [String: [AnalyticsItem]] = [:]
        var occurrenceCounter: [String: Int] = [:]
        for row in snapshot.items.sorted(by: { $0.rowID < $1.rowID }) {
            let occurrenceKey = (row.receiptBarcode ?? "") + "\u{0}" + (row.itemNumber ?? "")
            let occurrence = occurrenceCounter[occurrenceKey, default: 0]
            occurrenceCounter[occurrenceKey] = occurrence + 1

            guard let barcode = row.receiptBarcode, receiptsByBarcode[barcode] != nil else {
                exclude(.itemOrphan)
                continue
            }
            guard let itemNumber = row.itemNumber, !isBlank(itemNumber) else {
                exclude(.itemMissingItemNumber)
                continue
            }
            guard let quantity = row.quantity, quantity.isFinite, quantity > 0 else {
                exclude(.itemInvalidQuantity)
                continue
            }
            guard let unitPrice = row.unitPrice, unitPrice.isFinite, unitPrice >= 0,
                  let lineTotal = wholeCents(unitPrice * quantity * 100)
            else {
                exclude(.itemInvalidPrice)
                continue
            }
            let unitRaw = unitPrice * 100
            let unitPriceCents = abs(unitRaw - unitRaw.rounded()) < 1e-6 ? wholeCents(unitRaw) : nil

            itemsByBarcode[barcode, default: []].append(
                AnalyticsItem(
                    id: ids.itemID(receiptBarcode: barcode, itemNumber: itemNumber, occurrence: occurrence),
                    itemNumber: itemNumber,
                    description: row.description ?? "",
                    quantity: quantity,
                    lineTotalCents: lineTotal,
                    unitPriceCents: unitPriceCents
                )
            )
        }

        let bundles = receiptsByBarcode
            .map { barcode, receipt in
                AnalyticsReceiptBundle(
                    receipt: receipt,
                    items: (itemsByBarcode[barcode] ?? []).sorted { $0.id < $1.id }
                )
            }
            .sorted { $0.receipt.id < $1.receipt.id }

        // Returns and price adjustments, grouped by their source transaction.
        var groups: [String: AnalyticsTransactionGroup] = [:]
        func group(_ transactionBarcode: String) -> String {
            if groups[transactionBarcode] == nil {
                groups[transactionBarcode] = AnalyticsTransactionGroup(
                    transactionId: ids.transactionID(transactionBarcode: transactionBarcode),
                    returns: [],
                    priceAdjustments: []
                )
            }
            return transactionBarcode
        }

        for row in snapshot.returns {
            guard let txn = row.transactionBarcode, !isBlank(txn),
                  let itemNumber = row.itemNumber, !isBlank(itemNumber)
            else {
                exclude(.returnMissingKey)
                continue
            }
            guard let quantity = row.returnedQuantity, quantity.isFinite, quantity > 0 else {
                exclude(.returnInvalidQuantity)
                continue
            }
            if let amount = row.merchandiseAmount, !(amount.isFinite && amount >= 0) {
                exclude(.returnInvalidAmount)
                continue
            }
            let key = group(txn)
            groups[key]!.returns.append(
                AnalyticsReturn(
                    id: ids.returnID(transactionBarcode: txn, itemNumber: itemNumber),
                    transactionId: groups[key]!.transactionId,
                    itemNumber: itemNumber,
                    returnDate: calendarDate(row.returnDate),
                    warehouse: text(row.warehouse),
                    quantity: quantity,
                    description: text(row.description),
                    transactionType: text(row.transactionType),
                    merchandiseAmountCents: row.merchandiseAmount.flatMap { wholeCents($0 * 100) },
                    transactionTotalCents: row.transactionTotal.flatMap { wholeCents($0 * 100) }
                )
            )
        }

        for row in snapshot.priceAdjustments {
            guard let txn = row.transactionBarcode, !isBlank(txn),
                  let itemNumber = row.itemNumber, !isBlank(itemNumber)
            else {
                exclude(.adjustmentMissingKey)
                continue
            }
            guard let amount = row.adjustmentAmount, amount.isFinite, amount >= 0,
                  let amountCents = wholeCents(amount * 100)
            else {
                exclude(.adjustmentInvalidAmount)
                continue
            }
            guard let total = row.transactionTotal, total.isFinite, let totalCents = wholeCents(total * 100) else {
                exclude(.adjustmentMissingTransactionTotal)
                continue
            }
            let adjustedQuantity = row.adjustedQuantity.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let references = (row.referenceLineNumber ?? "")
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let key = group(txn)
            groups[key]!.priceAdjustments.append(
                AnalyticsPriceAdjustment(
                    id: ids.adjustmentID(transactionBarcode: txn, itemNumber: itemNumber),
                    transactionId: groups[key]!.transactionId,
                    itemNumber: itemNumber,
                    adjustmentDate: calendarDate(row.adjustmentDate),
                    warehouse: text(row.warehouse),
                    amountCents: amountCents,
                    adjustedQuantity: adjustedQuantity,
                    referenceLineNumbers: references,
                    transactionType: text(row.transactionType),
                    transactionTotalCents: totalCents
                )
            )
        }

        // Rows of one transaction must agree on transaction-level fields; the
        // server rejects disagreeing transactions, and guessing which row is
        // right would invent data, so the whole transaction is left out.
        var transactions: [AnalyticsTransactionGroup] = []
        for var group in groups.values {
            let fields = group.returns.map {
                TransactionFields(date: $0.returnDate, warehouse: $0.warehouse, type: $0.transactionType, total: $0.transactionTotalCents)
            } + group.priceAdjustments.map {
                TransactionFields(date: $0.adjustmentDate, warehouse: $0.warehouse, type: $0.transactionType, total: $0.transactionTotalCents)
            }
            if let first = fields.first, fields.contains(where: { $0 != first }) {
                exclude(.transactionInconsistent, group.rowCount)
                continue
            }
            group.returns.sort { $0.id < $1.id }
            group.priceAdjustments.sort { $0.id < $1.id }
            transactions.append(group)
        }
        transactions.sort { $0.transactionId < $1.transactionId }

        return AnalyticsDataset(receipts: bundles, transactions: transactions, exclusions: exclusions)
    }

    // MARK: Helpers

    private struct TransactionFields: Equatable {
        var date: String?
        var warehouse: String?
        var type: String?
        var total: Int?
    }

    static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func text(_ value: String?) -> String? {
        guard let value, !isBlank(value) else { return nil }
        return value
    }

    /// Rounds half away from zero; nil if not representable as a safe integer.
    static func wholeCents(_ value: Double) -> Int? {
        let rounded = value.rounded()
        guard rounded.isFinite, abs(rounded) <= 9_007_199_254_740_991 else { return nil }
        return Int(rounded)
    }

    /// A real calendar date written exactly as YYYY-MM-DD, otherwise nil.
    static func calendarDate(_ value: String?) -> String? {
        guard let value, value.count == 10 else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), day >= 1
        else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return day <= daysInMonth ? value : nil
    }
}
