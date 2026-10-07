import Foundation
import SQLite3

struct ReceiptMatch: Identifiable {
    let id = UUID()
    let itemNumber: String
    let description: String
    let unitPrice: Double
    let quantity: Double
    let barcode: String
    let date: String
    let warehouse: String
    let withinWindow: Bool
    let qualifies: Bool
    let savings: Double

    var isOnlineOrder: Bool {
        warehouse.hasPrefix("Online Order")
    }

    var hasWarehouseReceiptBarcode: Bool {
        !isOnlineOrder && !barcode.isEmpty && !barcode.hasPrefix("WHSE_")
    }
}

struct ItemPurchaseRecord: Identifiable {
    let id = UUID()
    let itemNumber: String
    let description: String
    let unitPrice: Double
    let quantity: Double
    let receiptIdentifier: String
    let date: String
    let warehouse: String

    var lineTotal: Double {
        unitPrice * quantity
    }

    var isOnlineOrder: Bool {
        warehouse.hasPrefix("Online Order")
    }

    var hasWarehouseReceiptBarcode: Bool {
        !isOnlineOrder && !receiptIdentifier.isEmpty && !receiptIdentifier.hasPrefix("WHSE_")
    }
}

struct PriceAdjustmentRecord: Identifiable {
    let id: Int64
    let transactionBarcode: String
    let itemNumber: String
    let adjustmentDate: String
    let warehouse: String
    let adjustmentAmount: Double
    let adjustedQuantity: Double?
    let referenceLineNumber: String
    let transactionType: String
    let transactionTotal: Double
}

struct ItemReturnRecord: Identifiable {
    let id: Int64
    let transactionBarcode: String
    let itemNumber: String
    let returnDate: String
    let warehouse: String
    let returnedQuantity: Double
    let description: String
    let transactionType: String
    let merchandiseAmount: Double?
    let transactionTotal: Double?
}

struct OnlineOrderSyncSummary {
    let orderNumber: String
    let orderHeaderId: String
    let orderDate: String
    let summarySignature: String
}

struct OnlineOrderSyncPlan {
    let candidates: [OnlineOrderSyncSummary]
    let listed: Int
    let existing: Int
    let new: Int
    let recent: Int
    let changed: Int
    let skipped: Int
}

class DBManager {
    static let shared = DBManager()
    var db: OpaquePointer?

    init(inMemory: Bool = false) { openDatabase(inMemory: inMemory) }

    // The on-disk location of the live database, shared with BackupManager
    // so backup/restore never hardcodes this path a second time.
    static func databaseFileURL() -> URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("costco.db")
    }

    // Closes the live connection so the underlying file can be safely
    // replaced during restore. Safe to call even if already closed.
    func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    func openDatabase(inMemory: Bool = false) {
        let databasePath: String
        if inMemory {
            databasePath = ":memory:"
        } else {
            let fileManager = FileManager.default
            guard let docUrl = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            databasePath = docUrl.appendingPathComponent("costco.db").path
        }

        if sqlite3_open(databasePath, &db) != SQLITE_OK { return }

        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS receipts (barcode TEXT PRIMARY KEY, date TEXT, warehouse TEXT);", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY AUTOINCREMENT, receipt_barcode TEXT, item_number TEXT, description TEXT, unit_price REAL, quantity REAL);", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS price_adjustments (id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_barcode TEXT NOT NULL, item_number TEXT NOT NULL, adjustment_date TEXT, warehouse TEXT, adjustment_amount REAL NOT NULL, adjusted_quantity REAL, reference_line_number TEXT, transaction_type TEXT, transaction_total REAL, UNIQUE(transaction_barcode, item_number));", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS item_returns (id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_barcode TEXT NOT NULL, item_number TEXT NOT NULL, return_date TEXT, warehouse TEXT, returned_quantity REAL NOT NULL, description TEXT, transaction_type TEXT, merchandise_amount REAL, transaction_total REAL, UNIQUE(transaction_barcode, item_number));", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS online_sync_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS online_order_sync_state (order_number TEXT PRIMARY KEY, order_header_id TEXT, order_date TEXT, summary_signature TEXT, detail_synced_at TEXT, last_seen_at TEXT, detail_summary_signature TEXT);", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE online_order_sync_state ADD COLUMN detail_summary_signature TEXT;", nil, nil, nil)
    }

    func getReceiptCount() -> Int {
        var count = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM receipts", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func getOnlineOrderCount() -> Int {

        var count = 0
        var stmt: OpaquePointer?

        let sql = """
            SELECT COUNT(*)
            FROM receipts
            WHERE warehouse LIKE 'Online Order%';
            """

        if sqlite3_prepare_v2(
            db,
            sql,
            -1,
            &stmt,
            nil
        ) == SQLITE_OK {

            if sqlite3_step(stmt) ==
                SQLITE_ROW {

                count =
                    Int(
                        sqlite3_column_int(
                            stmt,
                            0
                        )
                    )
            }
        }

        sqlite3_finalize(stmt)

        return count
    }


    func getWarehouseReceiptCount() -> Int {

        var count = 0
        var stmt: OpaquePointer?

        let sql = """
            SELECT COUNT(*)
            FROM receipts
            WHERE warehouse NOT LIKE 'Online Order%';
            """

        if sqlite3_prepare_v2(
            db,
            sql,
            -1,
            &stmt,
            nil
        ) == SQLITE_OK {

            if sqlite3_step(stmt) ==
                SQLITE_ROW {

                count =
                    Int(
                        sqlite3_column_int(
                            stmt,
                            0
                        )
                    )
            }
        }

        sqlite3_finalize(stmt)

        return count
    }

    // Count real paid prices, not merely receipt headers or captured JSON packets.
    func getPricedItemCount() -> Int {
        var count = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM items WHERE unit_price > 0", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func getPriceAdjustmentCount() -> Int {
        var count = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM price_adjustments", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func hasValidOnlineOrder(_ orderNumber: String) -> Bool {
        let sql = """
            SELECT 1
            FROM receipts r
            WHERE r.barcode = ?
              AND r.warehouse LIKE 'Online Order%'
              AND EXISTS (
                  SELECT 1
                  FROM items i
                  WHERE i.receipt_barcode = r.barcode
                    AND i.unit_price > 0
                    AND i.quantity > 0
              )
            LIMIT 1;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return false
        }

        bindText(stmt, 1, orderNumber)
        let exists = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        return exists
    }

    func prepareOnlineSync(
        summaries: [OnlineOrderSyncSummary],
        now: Date = Date()
    ) -> OnlineOrderSyncPlan {
        let existingOrders = validOnlineOrderNumbers()
        let storedStates = onlineOrderStates()
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -45,
            to: Calendar.current.startOfDay(for: now)
        ) ?? now

        var candidates: [OnlineOrderSyncSummary] = []
        var existingCount = 0
        var newCount = 0
        var recentCount = 0
        var changedCount = 0
        var skippedCount = 0
        let timestamp = ISO8601DateFormatter().string(from: now)

        for summary in summaries {
            let exists = existingOrders.contains(summary.orderNumber)
            let isRecent = onlineOrderDate(summary.orderDate).map { $0 >= cutoff } ?? true
            let previousState = storedStates[summary.orderNumber]
            let previousSignature = previousState?.summarySignature
            let changed = previousSignature.map {
                !$0.isEmpty && $0 != summary.summarySignature
            } ?? false
            let establishBaseline =
                exists &&
                !isRecent &&
                !changed &&
                previousState?.detailSummarySignature == nil

            if exists { existingCount += 1 } else { newCount += 1 }
            if isRecent { recentCount += 1 }
            if changed { changedCount += 1 }

            updateOnlineOrderSeen(
                summary,
                timestamp: timestamp,
                establishBaseline: establishBaseline
            )

            let detailMatchesCurrentSummary =
                establishBaseline ||
                previousState?.detailSummarySignature ==
                    summary.summarySignature

            if !exists ||
                isRecent ||
                changed ||
                !detailMatchesCurrentSummary {
                candidates.append(summary)
            } else {
                skippedCount += 1
            }
        }

        return OnlineOrderSyncPlan(
            candidates: candidates,
            listed: summaries.count,
            existing: existingCount,
            new: newCount,
            recent: recentCount,
            changed: changedCount,
            skipped: skippedCount
        )
    }

    func recordOnlineDetailSuccess(
        _ summary: OnlineOrderSyncSummary,
        now: Date = Date()
    ) {
        let timestamp = ISO8601DateFormatter().string(from: now)
        let sql = """
            INSERT INTO online_order_sync_state (
                order_number, order_header_id, order_date, summary_signature,
                detail_synced_at, last_seen_at, detail_summary_signature
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(order_number) DO UPDATE SET
                order_header_id = excluded.order_header_id,
                order_date = excluded.order_date,
                summary_signature = excluded.summary_signature,
                detail_synced_at = excluded.detail_synced_at,
                last_seen_at = excluded.last_seen_at,
                detail_summary_signature = excluded.detail_summary_signature;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return
        }

        bindText(stmt, 1, summary.orderNumber)
        bindText(stmt, 2, summary.orderHeaderId)
        bindText(stmt, 3, summary.orderDate)
        bindText(stmt, 4, summary.summarySignature)
        bindText(stmt, 5, timestamp)
        bindText(stmt, 6, timestamp)
        bindText(stmt, 7, summary.summarySignature)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func markOnlineBackfillComplete(now: Date = Date()) {
        let sql = """
            INSERT INTO online_sync_metadata (key, value)
            VALUES ('historical_backfill_completed_at', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return
        }

        bindText(stmt, 1, ISO8601DateFormatter().string(from: now))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        sqlite3_exec(
            db,
            "INSERT INTO online_sync_metadata (key, value) VALUES ('historical_backfill_version', '1') ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            nil,
            nil,
            nil
        )
    }

    func isOnlineBackfillComplete() -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM online_sync_metadata WHERE key = 'historical_backfill_completed_at' LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return false
        }

        let complete = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        return complete
    }

    private func validOnlineOrderNumbers() -> Set<String> {
        let sql = """
            SELECT r.barcode
            FROM receipts r
            WHERE r.warehouse LIKE 'Online Order%'
              AND EXISTS (
                  SELECT 1
                  FROM items i
                  WHERE i.receipt_barcode = r.barcode
                    AND i.unit_price > 0
                    AND i.quantity > 0
              );
            """

        var result = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return result
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = sqlite3_column_text(stmt, 0) {
                result.insert(String(cString: value))
            }
        }

        sqlite3_finalize(stmt)
        return result
    }

    private struct StoredOnlineOrderState {
        let summarySignature: String
        let detailSummarySignature: String?
    }

    private func onlineOrderStates() -> [String: StoredOnlineOrderState] {
        var result: [String: StoredOnlineOrderState] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT order_number, summary_signature, detail_summary_signature FROM online_order_sync_state;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return result
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let orderText = sqlite3_column_text(stmt, 0) else { continue }
            let orderNumber = String(cString: orderText)
            let signature = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let detailSignature = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            result[orderNumber] = StoredOnlineOrderState(
                summarySignature: signature,
                detailSummarySignature: detailSignature
            )
        }

        sqlite3_finalize(stmt)
        return result
    }

    private func updateOnlineOrderSeen(
        _ summary: OnlineOrderSyncSummary,
        timestamp: String,
        establishBaseline: Bool
    ) {
        let sql = """
            INSERT INTO online_order_sync_state (
                order_number, order_header_id, order_date, summary_signature,
                detail_synced_at, last_seen_at, detail_summary_signature
            ) VALUES (?, ?, ?, ?, NULL, ?, ?)
            ON CONFLICT(order_number) DO UPDATE SET
                order_header_id = excluded.order_header_id,
                order_date = excluded.order_date,
                summary_signature = excluded.summary_signature,
                last_seen_at = excluded.last_seen_at,
                detail_summary_signature = CASE
                    WHEN ? = 1 THEN excluded.detail_summary_signature
                    ELSE online_order_sync_state.detail_summary_signature
                END;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return
        }

        bindText(stmt, 1, summary.orderNumber)
        bindText(stmt, 2, summary.orderHeaderId)
        bindText(stmt, 3, summary.orderDate)
        bindText(stmt, 4, summary.summarySignature)
        bindText(stmt, 5, timestamp)
        if establishBaseline {
            bindText(stmt, 6, summary.summarySignature)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_int(stmt, 7, establishBaseline ? 1 : 0)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func onlineOrderDate(_ value: String) -> Date? {
        let prefix = String(value.prefix(10))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: prefix)
    }

    // Never silently translate a missing or malformed amount to $0.00.
    private func parseNumeric(_ value: Any?) -> Double? {
        guard let value = value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        guard let raw = value as? String else { return nil }
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        let parenthesized = cleaned.hasPrefix("(") && cleaned.hasSuffix(")")
        if parenthesized { cleaned = String(cleaned.dropFirst().dropLast()) }
        let trailingMinus = cleaned.hasSuffix("-")
        if trailingMinus { cleaned.removeLast() }
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return (parenthesized || trailingMinus) ? -abs(value) : value
    }

    // SQLITE_TRANSIENT copies the UTF-8 string before the temporary buffer expires.
    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func normalizedNumber(_ value: Any?) -> String {
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber { text = number.stringValue }
        else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutZeroes = trimmed.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        return withoutZeroes.isEmpty ? "0" : withoutZeroes
    }

    private func normalizedDate(_ raw: String) -> String {
        let pattern = #"^\d{4}-\d{2}-\d{2}|^\d{1,2}/\d{1,2}/\d{4}"#
        guard let range = raw.range(of: pattern, options: .regularExpression) else { return "" }
        let dateText = String(raw[range])
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = TimeZone(secondsFromGMT: 0)
        reader.isLenient = false
        let writer = DateFormatter()
        writer.locale = Locale(identifier: "en_US_POSIX")
        writer.timeZone = TimeZone(secondsFromGMT: 0)
        writer.dateFormat = "yyyy-MM-dd"
        for format in ["yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy"] {
            reader.dateFormat = format
            if let parsed = reader.date(from: dateText) { return writer.string(from: parsed) }
        }
        return ""
    }

    private struct WarehouseItem {
        var itemNumber: String
        var description: String
        var total: Double
        var quantity: Double
    }

    private struct PendingPriceAdjustment {
        var amount: Double
        var quantity: Double?
        var referenceLineNumbers: [String]
    }

    private struct PendingItemReturn {
        var returnedQuantity: Double
        var merchandiseAmount: Double?
        var description: String
    }

    // Classifies qualifying negative-unit merchandise return lines from a
    // warehouse transaction, independent of transactionType (observed real
    // "Sales"-typed transactions can contain genuine returns). Slash-prefixed
    // adjustment/promo-reference lines never contribute, regardless of sign.
    private func qualifyingItemReturns(
        in sourceItems: [[String: Any]]
    ) -> [String: PendingItemReturn] {
        var returns: [String: PendingItemReturn] = [:]

        for item in sourceItems {
            let description = item["itemDescription01"] as? String ?? ""
            let isSlashPrefixed = description
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("/")
            guard !isSlashPrefixed else { continue }

            let itemNum = normalizedNumber(item["itemNumber"])
            guard !itemNum.isEmpty else { continue }

            guard let unit = parseNumeric(item["unit"]), unit < 0 else { continue }

            let returnedQuantity = abs(unit)
            let merchandiseAmount = parseNumeric(item["amount"]).map { abs($0) }

            if var existing = returns[itemNum] {
                existing.returnedQuantity += returnedQuantity
                if let merchandiseAmount {
                    existing.merchandiseAmount = (existing.merchandiseAmount ?? 0) + merchandiseAmount
                }
                returns[itemNum] = existing
            } else {
                returns[itemNum] = PendingItemReturn(
                    returnedQuantity: returnedQuantity,
                    merchandiseAmount: merchandiseAmount,
                    description: description
                )
            }
        }

        return returns
    }

    private func storeItemReturns(
        _ returns: [String: PendingItemReturn],
        barcode: String,
        date: String,
        warehouse: String,
        transactionType: String,
        transactionTotal: Double?
    ) {
        let sql = """
            INSERT INTO item_returns (
                transaction_barcode, item_number, return_date, warehouse,
                returned_quantity, description, transaction_type,
                merchandise_amount, transaction_total
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(transaction_barcode, item_number) DO UPDATE SET
                return_date = excluded.return_date,
                warehouse = excluded.warehouse,
                returned_quantity = excluded.returned_quantity,
                description = excluded.description,
                transaction_type = excluded.transaction_type,
                merchandise_amount = excluded.merchandise_amount,
                transaction_total = excluded.transaction_total;
            """

        for (itemNumber, pending) in returns {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                continue
            }

            bindText(stmt, 1, barcode)
            bindText(stmt, 2, itemNumber)
            bindText(stmt, 3, date)
            bindText(stmt, 4, warehouse)
            sqlite3_bind_double(stmt, 5, pending.returnedQuantity)
            bindText(stmt, 6, pending.description)
            bindText(stmt, 7, transactionType)
            if let merchandiseAmount = pending.merchandiseAmount {
                sqlite3_bind_double(stmt, 8, merchandiseAmount)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            if let transactionTotal {
                sqlite3_bind_double(stmt, 9, transactionTotal)
            } else {
                sqlite3_bind_null(stmt, 9)
            }

            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func referencedItemNumber(from description: String) -> String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let rawReference = String(trimmed.dropFirst())
        let compactReference = rawReference
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")

        guard !compactReference.isEmpty,
              compactReference.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }

        let normalized = normalizedNumber(compactReference)
        return normalized.isEmpty ? nil : normalized
    }

    private func standalonePriceAdjustments(
        in receipt: [String: Any],
        sourceItems: [[String: Any]]
    ) -> [String: PendingPriceAdjustment] {
        guard let transactionTotal = parseNumeric(receipt["total"]), transactionTotal < 0,
              let totalItemCount = parseNumeric(receipt["totalItemCount"]), totalItemCount == 0 else {
            return [:]
        }

        var adjustments: [String: PendingPriceAdjustment] = [:]
        var hasNegativeNonSlashLine = false
        var hasPositiveNormalSaleLine = false

        for item in sourceItems {
            guard let amount = parseNumeric(item["amount"]) else { continue }
            let description = item["itemDescription01"] as? String ?? ""
            let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSlashLine = trimmedDescription.hasPrefix("/")

            if amount < 0, !isSlashLine {
                hasNegativeNonSlashLine = true
            } else if amount > 0, !isSlashLine {
                hasPositiveNormalSaleLine = true
            }

            guard amount < 0,
                  let referencedItemNumber = referencedItemNumber(from: description) else {
                continue
            }

            let rawQuantity = parseNumeric(item["unit"])
            let quantity = rawQuantity.flatMap { value in
                let absoluteValue = abs(value)
                return absoluteValue > 0 ? absoluteValue : nil
            }
            let referenceLineNumber = normalizedNumber(item["itemNumber"])

            if var existing = adjustments[referencedItemNumber] {
                existing.amount += abs(amount)
                if let quantity {
                    existing.quantity = (existing.quantity ?? 0) + quantity
                }
                if !referenceLineNumber.isEmpty,
                   !existing.referenceLineNumbers.contains(referenceLineNumber) {
                    existing.referenceLineNumbers.append(referenceLineNumber)
                }
                adjustments[referencedItemNumber] = existing
            } else {
                adjustments[referencedItemNumber] = PendingPriceAdjustment(
                    amount: abs(amount),
                    quantity: quantity,
                    referenceLineNumbers: referenceLineNumber.isEmpty ? [] : [referenceLineNumber]
                )
            }
        }

        guard !hasNegativeNonSlashLine, !hasPositiveNormalSaleLine else { return [:] }
        return adjustments
    }

    private func storePriceAdjustments(
        _ adjustments: [String: PendingPriceAdjustment],
        barcode: String,
        date: String,
        warehouse: String,
        transactionType: String,
        transactionTotal: Double
    ) {
        let sql = """
            INSERT INTO price_adjustments (
                transaction_barcode, item_number, adjustment_date, warehouse,
                adjustment_amount, adjusted_quantity, reference_line_number,
                transaction_type, transaction_total
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(transaction_barcode, item_number) DO UPDATE SET
                adjustment_date = excluded.adjustment_date,
                warehouse = excluded.warehouse,
                adjustment_amount = excluded.adjustment_amount,
                adjusted_quantity = excluded.adjusted_quantity,
                reference_line_number = excluded.reference_line_number,
                transaction_type = excluded.transaction_type,
                transaction_total = excluded.transaction_total;
            """

        for (itemNumber, adjustment) in adjustments {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                continue
            }

            bindText(stmt, 1, barcode)
            bindText(stmt, 2, itemNumber)
            bindText(stmt, 3, date)
            bindText(stmt, 4, warehouse)
            sqlite3_bind_double(stmt, 5, adjustment.amount)
            if let quantity = adjustment.quantity {
                sqlite3_bind_double(stmt, 6, quantity)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            bindText(stmt, 7, adjustment.referenceLineNumbers.joined(separator: ","))
            bindText(stmt, 8, transactionType)
            sqlite3_bind_double(stmt, 9, transactionTotal)

            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
    
    private func findOnlineOrderPages(
        in value: Any
    ) -> [[String: Any]] {

        var pages: [[String: Any]] = []

        if let dictionary =
            value as? [String: Any] {

            if let orders =
                dictionary["bcOrders"]
                    as? [[String: Any]],
               !orders.isEmpty {

                pages.append(dictionary)
            }

            for child in dictionary.values {

                pages.append(
                    contentsOf:
                        findOnlineOrderPages(
                            in: child
                        )
                )
            }

        } else if let array =
            value as? [Any] {

            for child in array {

                pages.append(
                    contentsOf:
                        findOnlineOrderPages(
                            in: child
                        )
                )
            }
        }

        return pages
    }

    func ingestOnlineJSON(_ jsonString: String) -> Bool {
        let changesBefore = sqlite3_total_changes(db)
        ingestJSON(jsonString)
        return sqlite3_total_changes(db) > changesBefore
    }

    func ingestJSON(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            print("Costco GraphQL errors:", errors.compactMap { $0["message"] as? String }.joined(separator: "; "))
            return
        }
        guard let dataDict = root["data"] as? [String: Any] else { return }

        // Warehouse receipts: amount is the extended line total and unit is quantity.
        if let receiptsWithCounts = dataDict["receiptsWithCounts"] as? [String: Any],
           let receiptsArray = receiptsWithCounts["receipts"] as? [[String: Any]] {
            for receipt in receiptsArray {
                guard let sourceItems = receipt["itemArray"] as? [[String: Any]], !sourceItems.isEmpty else { continue }

                let rawBarcode = receipt["transactionBarcode"] as? String ?? ""
                let date = normalizedDate(receipt["transactionDateTime"] as? String ?? "")
                let warehouse = receipt["warehouseName"] as? String ?? "Warehouse"
                let barcode = !rawBarcode.isEmpty ? rawBarcode : "WHSE_\(date)_\(warehouse)".replacingOccurrences(of: " ", with: "_")
                let transactionType = receipt["transactionType"] as? String ?? ""

                if let transactionTotal = parseNumeric(receipt["total"]) {
                    let adjustments = standalonePriceAdjustments(
                        in: receipt,
                        sourceItems: sourceItems
                    )
                    if !adjustments.isEmpty {
                        storePriceAdjustments(
                            adjustments,
                            barcode: barcode,
                            date: date,
                            warehouse: warehouse,
                            transactionType: transactionType,
                            transactionTotal: transactionTotal
                        )
                    }
                }

                // Return-quantity capture is independent of transactionType:
                // observed real "Sales"-typed transactions also contain
                // genuine negative-unit merchandise return lines.
                let qualifyingReturns = qualifyingItemReturns(in: sourceItems)
                if !qualifyingReturns.isEmpty {
                    storeItemReturns(
                        qualifyingReturns,
                        barcode: barcode,
                        date: date,
                        warehouse: warehouse,
                        transactionType: transactionType,
                        transactionTotal: parseNumeric(receipt["total"])
                    )
                }

                if transactionType.localizedCaseInsensitiveContains("refund") { continue }

                var products: [String: WarehouseItem] = [:]
                var discounts: [String: Double] = [:]

                for item in sourceItems {
                    let itemNum = normalizedNumber(item["itemNumber"])
                    let description = item["itemDescription01"] as? String ?? ""
                    let amount = parseNumeric(item["amount"])
                    let count = parseNumeric(item["unit"]) ?? 1

                    // Costco can put an instant-savings line under another item number.
                    // Its description contains /<original item number> and its amount is negative.
                    if description.hasPrefix("/"), let amount = amount, amount < 0 {
                        let parent = normalizedNumber(String(description.dropFirst()).trimmingCharacters(in: .whitespaces))
                        if !parent.isEmpty { discounts[parent, default: 0] += amount }
                        continue
                    }

                    // A negative line is a return or reversal, not a new purchase.
                    guard !itemNum.isEmpty, count > 0 else { continue }
                    let total: Double
                    if let amount = amount, amount > 0 {
                        total = amount
                    } else if let unitPrice = parseNumeric(item["itemUnitPriceAmount"] ?? item["unitPrice"]), unitPrice > 0 {
                        total = unitPrice * count
                    } else {
                        #if DEBUG
                        print("Costco: no usable price for item \(itemNum). amount=\(String(describing: item["amount"])) unit=\(String(describing: item["unit"])) itemUnitPriceAmount=\(String(describing: item["itemUnitPriceAmount"]))")
                        #endif
                        continue
                    }

                    if var existing = products[itemNum] {
                        existing.total += total
                        existing.quantity += count
                        products[itemNum] = existing
                    } else {
                        products[itemNum] = WarehouseItem(itemNumber: itemNum, description: description, total: total, quantity: count)
                    }
                }

                // If the response has no priced products, do not destroy an earlier good import.
                guard !products.isEmpty else { continue }

                let insertReceipt = "INSERT OR REPLACE INTO receipts (barcode, date, warehouse) VALUES (?, ?, ?);"
                var stmtR: OpaquePointer?
                if sqlite3_prepare_v2(db, insertReceipt, -1, &stmtR, nil) == SQLITE_OK {
                    bindText(stmtR, 1, barcode)
                    bindText(stmtR, 2, date)
                    bindText(stmtR, 3, warehouse)
                    sqlite3_step(stmtR)
                }
                sqlite3_finalize(stmtR)

                let clearItems = "DELETE FROM items WHERE receipt_barcode = ?;"
                var stmtC: OpaquePointer?
                if sqlite3_prepare_v2(db, clearItems, -1, &stmtC, nil) == SQLITE_OK {
                    bindText(stmtC, 1, barcode)
                    sqlite3_step(stmtC)
                }
                sqlite3_finalize(stmtC)

                for product in products.values {
                    let netTotal = product.total + (discounts[product.itemNumber] ?? 0)
                    guard netTotal >= 0, product.quantity > 0 else { continue }
                    let unitPrice = netTotal / product.quantity
                    let insertItem = "INSERT INTO items (receipt_barcode, item_number, description, unit_price, quantity) VALUES (?, ?, ?, ?, ?);"
                    var stmtI: OpaquePointer?
                    if sqlite3_prepare_v2(db, insertItem, -1, &stmtI, nil) == SQLITE_OK {
                        bindText(stmtI, 1, barcode)
                        bindText(stmtI, 2, product.itemNumber)
                        bindText(stmtI, 3, product.description)
                        sqlite3_bind_double(stmtI, 4, unitPrice)
                        sqlite3_bind_double(stmtI, 5, product.quantity)
                        sqlite3_step(stmtI)
                    }
                    sqlite3_finalize(stmtI)
                }
            }
        }

        // Preserve online-order ingestion; do not invent per-item prices from order totals.
        let onlineOrdersArray =
            findOnlineOrderPages(
                in: dataDict
            )

        if !onlineOrdersArray.isEmpty {
            for page in onlineOrdersArray {
                guard let orders = page["bcOrders"] as? [[String: Any]] else { continue }
                for order in orders {
                    guard let lineItems = order["orderLineItems"] as? [[String: Any]], !lineItems.isEmpty else { continue }
                    let orderNum = order["orderNumber"] as? String ?? order["orderHeaderId"] as? String ?? "ONLINE"
                    let date = normalizedDate(order["orderPlacedDate"] as? String ?? "")
                    let whseNum = order["warehouseNumber"] as? Int ?? 847
                    let warehouse = "Online Order (Fulfilling Whse #\(whseNum))"

                    var pricedItems: [(number: String, description: String, price: Double, quantity: Double)] = []
                    for item in lineItems {
                        let itemNum = normalizedNumber(item["itemNumber"] ?? item["itemId"])
                        let description = item["itemDescription"] as? String ?? ""
                        let quantity = parseNumeric(item["quantity"]) ?? 1
                        guard !itemNum.isEmpty, quantity > 0,
                              let unitPrice = parseNumeric(item["itemPrice"] ?? item["unitPrice"] ?? item["price"]), unitPrice > 0 else { continue }
                        pricedItems.append((itemNum, description, unitPrice, quantity))
                    }
                    guard !pricedItems.isEmpty else { continue }

                    let insertReceipt = "INSERT OR REPLACE INTO receipts (barcode, date, warehouse) VALUES (?, ?, ?);"
                    var stmtR: OpaquePointer?
                    if sqlite3_prepare_v2(db, insertReceipt, -1, &stmtR, nil) == SQLITE_OK {
                        bindText(stmtR, 1, orderNum)
                        bindText(stmtR, 2, date)
                        bindText(stmtR, 3, warehouse)
                        sqlite3_step(stmtR)
                    }
                    sqlite3_finalize(stmtR)

                    let clearItems = "DELETE FROM items WHERE receipt_barcode = ?;"
                    var stmtC: OpaquePointer?
                    if sqlite3_prepare_v2(db, clearItems, -1, &stmtC, nil) == SQLITE_OK {
                        bindText(stmtC, 1, orderNum)
                        sqlite3_step(stmtC)
                    }
                    sqlite3_finalize(stmtC)

                    for item in pricedItems {
                        let insertItem = "INSERT INTO items (receipt_barcode, item_number, description, unit_price, quantity) VALUES (?, ?, ?, ?, ?);"
                        var stmtI: OpaquePointer?
                        if sqlite3_prepare_v2(db, insertItem, -1, &stmtI, nil) == SQLITE_OK {
                            bindText(stmtI, 1, orderNum)
                            bindText(stmtI, 2, item.number)
                            bindText(stmtI, 3, item.description)
                            sqlite3_bind_double(stmtI, 4, item.price)
                            sqlite3_bind_double(stmtI, 5, item.quantity)
                            sqlite3_step(stmtI)
                        }
                        sqlite3_finalize(stmtI)
                    }
                }
            }
        }
    }

    func priceAdjustments(for itemNumber: String) -> [PriceAdjustmentRecord] {
        let cleanNumber = normalizedNumber(itemNumber)
        guard !cleanNumber.isEmpty else { return [] }

        let sql = """
            SELECT id, transaction_barcode, item_number, adjustment_date, warehouse,
                   adjustment_amount, adjusted_quantity, reference_line_number,
                   transaction_type, transaction_total
            FROM price_adjustments
            WHERE item_number = ? OR ltrim(item_number, '0') = ?
            ORDER BY adjustment_date DESC, id DESC;
            """

        var records: [PriceAdjustmentRecord] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return []
        }

        bindText(stmt, 1, cleanNumber)
        bindText(stmt, 2, cleanNumber)

        func text(at index: Int32) -> String {
            guard let value = sqlite3_column_text(stmt, index) else { return "" }
            return String(cString: value)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let adjustedQuantity: Double? =
                sqlite3_column_type(stmt, 6) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 6)

            records.append(
                PriceAdjustmentRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    transactionBarcode: text(at: 1),
                    itemNumber: text(at: 2),
                    adjustmentDate: text(at: 3),
                    warehouse: text(at: 4),
                    adjustmentAmount: sqlite3_column_double(stmt, 5),
                    adjustedQuantity: adjustedQuantity,
                    referenceLineNumber: text(at: 7),
                    transactionType: text(at: 8),
                    transactionTotal: sqlite3_column_double(stmt, 9)
                )
            )
        }

        sqlite3_finalize(stmt)
        return records
    }

    func itemReturns(for itemNumber: String) -> [ItemReturnRecord] {
        let cleanNumber = normalizedNumber(itemNumber)
        guard !cleanNumber.isEmpty else { return [] }

        let sql = """
            SELECT id, transaction_barcode, item_number, return_date, warehouse,
                   returned_quantity, description, transaction_type,
                   merchandise_amount, transaction_total
            FROM item_returns
            WHERE item_number = ? OR ltrim(item_number, '0') = ?
            ORDER BY return_date DESC, id DESC;
            """

        var records: [ItemReturnRecord] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return []
        }

        bindText(stmt, 1, cleanNumber)
        bindText(stmt, 2, cleanNumber)

        func text(at index: Int32) -> String {
            guard let value = sqlite3_column_text(stmt, index) else { return "" }
            return String(cString: value)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let merchandiseAmount: Double? =
                sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 8)

            let transactionTotal: Double? =
                sqlite3_column_type(stmt, 9) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 9)

            records.append(
                ItemReturnRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    transactionBarcode: text(at: 1),
                    itemNumber: text(at: 2),
                    returnDate: text(at: 3),
                    warehouse: text(at: 4),
                    returnedQuantity: sqlite3_column_double(stmt, 5),
                    description: text(at: 6),
                    transactionType: text(at: 7),
                    merchandiseAmount: merchandiseAmount,
                    transactionTotal: transactionTotal
                )
            )
        }

        sqlite3_finalize(stmt)
        return records
    }

    func purchaseHistory(for itemNumber: String) -> [ItemPurchaseRecord] {
        let cleanNumber = normalizedNumber(itemNumber)
        guard !cleanNumber.isEmpty else { return [] }

        let sql = """
            SELECT i.item_number, i.description, i.unit_price, i.quantity,
                   r.barcode, r.date, r.warehouse
            FROM items i
            JOIN receipts r ON r.barcode = i.receipt_barcode
            WHERE i.unit_price > 0
              AND (i.item_number = ? OR ltrim(i.item_number, '0') = ?)
            ORDER BY r.date DESC, i.id DESC;
            """

        var records: [ItemPurchaseRecord] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return []
        }

        bindText(stmt, 1, cleanNumber)
        bindText(stmt, 2, cleanNumber)

        func text(at index: Int32) -> String {
            guard let value = sqlite3_column_text(stmt, index) else { return "" }
            return String(cString: value)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(
                ItemPurchaseRecord(
                    itemNumber: text(at: 0),
                    description: text(at: 1),
                    unitPrice: sqlite3_column_double(stmt, 2),
                    quantity: sqlite3_column_double(stmt, 3),
                    receiptIdentifier: text(at: 4),
                    date: text(at: 5),
                    warehouse: text(at: 6)
                )
            )
        }

        sqlite3_finalize(stmt)
        return records
    }

    func queryMatch(itemNum: String, shelfPrice: Double) -> [ReceiptMatch] {
        let cleanNum = normalizedNumber(itemNum)
        guard !cleanNum.isEmpty, shelfPrice.isFinite, shelfPrice >= 0 else { return [] }
        var stmt: OpaquePointer?
        let queryString = """
            SELECT i.item_number, i.description, i.unit_price, i.quantity, r.barcode, r.date, r.warehouse
            FROM items i JOIN receipts r ON i.receipt_barcode = r.barcode
            WHERE i.unit_price > 0
              AND (i.item_number = ? OR ltrim(i.item_number, '0') = ?)
            ORDER BY r.date DESC
        """

        var matches: [ReceiptMatch] = []
        let today = Calendar.current.startOfDay(for: Date())
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: today)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"

        if sqlite3_prepare_v2(db, queryString, -1, &stmt, nil) == SQLITE_OK {
            bindText(stmt, 1, cleanNum)
            bindText(stmt, 2, cleanNum)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rItemNum = String(cString: sqlite3_column_text(stmt, 0))
                let rDesc = String(cString: sqlite3_column_text(stmt, 1))
                let rPrice = sqlite3_column_double(stmt, 2)
                let rQty = sqlite3_column_double(stmt, 3)
                let rBarcode = String(cString: sqlite3_column_text(stmt, 4))
                let dateStr = String(cString: sqlite3_column_text(stmt, 5)).prefix(10)
                let rWhse = String(cString: sqlite3_column_text(stmt, 6))
                let purchaseDate = formatter.date(from: String(dateStr)) ?? Date.distantPast
                let withinWindow = purchaseDate >= thirtyDaysAgo && purchaseDate <= today
                let savings = max(0, rPrice - shelfPrice) * rQty
                // A warehouse shelf tag cannot be used to automatically qualify an online order.
                let qualifies = withinWindow && savings > 0 && !rWhse.hasPrefix("Online Order")
                matches.append(ReceiptMatch(itemNumber: rItemNum, description: rDesc,
                    unitPrice: rPrice, quantity: rQty, barcode: rBarcode,
                    date: String(dateStr), warehouse: rWhse, withinWindow: withinWindow,
                    qualifies: qualifies, savings: savings))
            }
        }
        sqlite3_finalize(stmt)
        return matches
    }
}
