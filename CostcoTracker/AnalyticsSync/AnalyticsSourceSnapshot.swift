import Foundation
import SQLite3

// MARK: - Raw source rows
//
// Plain copies of the CostcoTracker SQLite rows, read without modification.
// Columns mirror DBManager's CREATE TABLE statements exactly; nothing is
// normalized here (that is AnalyticsExportBuilder's job).

nonisolated struct SourceReceiptRow: Equatable, Sendable {
    var barcode: String?
    var date: String?
    var warehouse: String?
}

nonisolated struct SourceItemRow: Equatable, Sendable {
    var rowID: Int64
    var receiptBarcode: String?
    var itemNumber: String?
    var description: String?
    var unitPrice: Double?
    var quantity: Double?
}

nonisolated struct SourceReturnRow: Equatable, Sendable {
    var rowID: Int64
    var transactionBarcode: String?
    var itemNumber: String?
    var returnDate: String?
    var warehouse: String?
    var returnedQuantity: Double?
    var description: String?
    var transactionType: String?
    var merchandiseAmount: Double?
    var transactionTotal: Double?
}

nonisolated struct SourcePriceAdjustmentRow: Equatable, Sendable {
    var rowID: Int64
    var transactionBarcode: String?
    var itemNumber: String?
    var adjustmentDate: String?
    var warehouse: String?
    var adjustmentAmount: Double?
    var adjustedQuantity: Double?
    var referenceLineNumber: String?
    var transactionType: String?
    var transactionTotal: Double?
}

nonisolated struct SourceSnapshot: Equatable, Sendable {
    var receipts: [SourceReceiptRow] = []
    var items: [SourceItemRow] = []
    var returns: [SourceReturnRow] = []
    var priceAdjustments: [SourcePriceAdjustmentRow] = []
}

nonisolated enum SourceSnapshotError: Error, Equatable {
    case databaseUnavailable
    case queryFailed(table: String)
}

// MARK: - SQLite reader (read-only)

nonisolated enum SourceSnapshotReader {

    /// Reads all analytics-relevant rows inside one read transaction so the
    /// snapshot is internally consistent. Executes SELECT statements only.
    static func read(database db: OpaquePointer?) throws -> SourceSnapshot {
        guard let db else { throw SourceSnapshotError.databaseUnavailable }

        // Only open (and later end) a read transaction if no other transaction
        // is active, so this can never commit someone else's work.
        let ownsTransaction = sqlite3_get_autocommit(db) != 0
            && sqlite3_exec(db, "BEGIN DEFERRED TRANSACTION", nil, nil, nil) == SQLITE_OK
        defer { if ownsTransaction { sqlite3_exec(db, "COMMIT", nil, nil, nil) } }

        var snapshot = SourceSnapshot()

        try query(db, table: "receipts", sql: "SELECT barcode, date, warehouse FROM receipts ORDER BY barcode") { s in
            snapshot.receipts.append(SourceReceiptRow(barcode: text(s, 0), date: text(s, 1), warehouse: text(s, 2)))
        }

        try query(
            db,
            table: "items",
            sql: "SELECT id, receipt_barcode, item_number, description, unit_price, quantity FROM items ORDER BY id"
        ) { s in
            snapshot.items.append(
                SourceItemRow(
                    rowID: sqlite3_column_int64(s, 0),
                    receiptBarcode: text(s, 1),
                    itemNumber: text(s, 2),
                    description: text(s, 3),
                    unitPrice: real(s, 4),
                    quantity: real(s, 5)
                )
            )
        }

        try query(
            db,
            table: "item_returns",
            sql: """
                SELECT id, transaction_barcode, item_number, return_date, warehouse, returned_quantity,
                       description, transaction_type, merchandise_amount, transaction_total
                FROM item_returns ORDER BY id
                """
        ) { s in
            snapshot.returns.append(
                SourceReturnRow(
                    rowID: sqlite3_column_int64(s, 0),
                    transactionBarcode: text(s, 1),
                    itemNumber: text(s, 2),
                    returnDate: text(s, 3),
                    warehouse: text(s, 4),
                    returnedQuantity: real(s, 5),
                    description: text(s, 6),
                    transactionType: text(s, 7),
                    merchandiseAmount: real(s, 8),
                    transactionTotal: real(s, 9)
                )
            )
        }

        try query(
            db,
            table: "price_adjustments",
            sql: """
                SELECT id, transaction_barcode, item_number, adjustment_date, warehouse, adjustment_amount,
                       adjusted_quantity, reference_line_number, transaction_type, transaction_total
                FROM price_adjustments ORDER BY id
                """
        ) { s in
            snapshot.priceAdjustments.append(
                SourcePriceAdjustmentRow(
                    rowID: sqlite3_column_int64(s, 0),
                    transactionBarcode: text(s, 1),
                    itemNumber: text(s, 2),
                    adjustmentDate: text(s, 3),
                    warehouse: text(s, 4),
                    adjustmentAmount: real(s, 5),
                    adjustedQuantity: real(s, 6),
                    referenceLineNumber: text(s, 7),
                    transactionType: text(s, 8),
                    transactionTotal: real(s, 9)
                )
            )
        }

        return snapshot
    }

    private static func query(
        _ db: OpaquePointer,
        table: String,
        sql: String,
        row: (OpaquePointer) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw SourceSnapshotError.queryFailed(table: table)
        }
        defer { sqlite3_finalize(statement) }

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                row(statement)
            } else if result == SQLITE_DONE {
                return
            } else {
                throw SourceSnapshotError.queryFailed(table: table)
            }
        }
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: pointer)
    }

    private static func real(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }
}
