import Foundation
import SQLite3
import Testing
@testable import AnalyticsSync

@Suite("Export builder")
struct ExportBuilderTests {

    private func build() throws -> AnalyticsDataset {
        AnalyticsExportBuilder.build(try Fixtures.sourceSnapshot(), ids: try AnalyticsIDDeriver(idKey: Fixtures.idKey))
    }

    @Test("Matches the golden export produced by the independent reference implementation")
    func golden() throws {
        let golden = try Fixtures.json("expected-export-v1.json")
        let expected = golden["export"] as! [String: Any]
        let actual = try exportCollections(try build())
        for collection in ["receipts", "items", "returns", "priceAdjustments"] {
            let want = expected[collection] as! [[String: Any]]
            let got = actual[collection]!
            #expect(got.count == want.count, "\(collection) count")
            for (g, w) in zip(got, want) {
                #expect(NSDictionary(dictionary: g).isEqual(to: w), "\(collection) \(w["id"] ?? "")")
            }
        }
        let expectedExclusions = golden["exclusions"] as! [String: Int]
        let actualExclusions = Dictionary(uniqueKeysWithValues: try build().exclusions.map { ($0.key.rawValue, $0.value) })
        #expect(actualExclusions == expectedExclusions)
    }

    @Test("Never includes raw barcodes, WHSE_ keys or order keys")
    func noRawKeys() throws {
        let dataset = try build()
        let json = String(decoding: try AnalyticsJSON.encode(AnalyticsSyncBatch(
            receipts: dataset.receipts,
            returns: dataset.transactions.flatMap(\.returns),
            priceAdjustments: dataset.transactions.flatMap(\.priceAdjustments)
        )), as: UTF8.self)
        for key in try Fixtures.rawSourceKeys() {
            #expect(!json.contains(key), "leaked a source key")
        }
        #expect(!json.contains("WHSE_"))
        for forbidden in ["barcode", "cookie", "token", "password", "session", "authorization", "orderNumber"] {
            #expect(!json.lowercased().contains("\"\(forbidden.lowercased())"), "forbidden field name \(forbidden)")
        }
    }

    @Test("Maps source semantics: source type, identifier kind, nulls and cents")
    func mappingRules() throws {
        let ids = try AnalyticsIDDeriver(idKey: Fixtures.idKey)
        let dataset = try build()
        let byId = Dictionary(uniqueKeysWithValues: dataset.receipts.map { ($0.receipt.id, $0) })

        let warehouse = try #require(byId[ids.receiptID(barcode: "99990000000000000001")])
        #expect(warehouse.receipt.sourceType == .warehouse)
        #expect(warehouse.receipt.identifierKind == .transactionBarcode)

        let synthesized = try #require(byId[ids.receiptID(barcode: "WHSE_2026-01-18_SYNTHETIC_SOUTH")])
        #expect(synthesized.receipt.identifierKind == .synthesizedWarehouseKey)
        let produce = try #require(synthesized.items.first { $0.itemNumber == "9000004" })
        #expect(produce.quantity == 1.37)
        #expect(produce.lineTotalCents == 411)
        #expect(produce.unitPriceCents == 300)

        let online = try #require(byId[ids.receiptID(barcode: "SYNTH-ORD-1001")])
        #expect(online.receipt.sourceType == .online)
        #expect(online.receipt.identifierKind == .onlineOrderKey)
        #expect(online.items.count == 2) // repeated online line kept, distinct IDs
        #expect(Set(online.items.map(\.id)).count == 2)

        let undated = try #require(byId[ids.receiptID(barcode: "99990000000000000004")])
        #expect(undated.receipt.purchaseDate == nil)
        #expect(undated.receipt.warehouse == "Warehouse") // placeholder kept verbatim, never invented away
        #expect(undated.items.first?.unitPriceCents == nil) // $10.00 / 3 is not a whole number of cents
        #expect(undated.items.first?.lineTotalCents == 1000)

        let invalidDate = try #require(byId[ids.receiptID(barcode: "99990000000000000005")])
        #expect(invalidDate.receipt.purchaseDate == nil) // 2026-02-30 is not a date
        #expect(invalidDate.receipt.warehouse == nil)    // "" is unknown

        let txn = try #require(dataset.transactions.first { $0.transactionId == ids.transactionID(transactionBarcode: "99990000000000000101") })
        #expect(txn.returns.count == 2)
        #expect(txn.returns.allSatisfy { $0.transactionTotalCents == -6650 }) // whole-transaction total, repeated, never summed
        #expect(txn.returns.allSatisfy { $0.sourcePurchaseId == nil })
        let lamp = try #require(txn.returns.first { $0.itemNumber == "9000005" })
        #expect(lamp.merchandiseAmountCents == 3999)

        let adjustments = dataset.transactions.flatMap(\.priceAdjustments)
        let multi = try #require(adjustments.first { $0.itemNumber == "9000002" })
        #expect(multi.referenceLineNumbers == ["9100002", "9100003"])
        let sparse = try #require(adjustments.first { $0.itemNumber == "9000003" })
        #expect(sparse.adjustmentDate == nil && sparse.warehouse == nil && sparse.transactionType == nil)
        #expect(sparse.adjustedQuantity == nil && sparse.referenceLineNumbers.isEmpty)
        #expect(adjustments.allSatisfy { $0.sourcePurchaseId == nil })
    }

    @Test("Encodes unknown values as explicit null, never omits fields")
    func explicitNulls() throws {
        let dataset = try build()
        let sparse = try #require(dataset.transactions.flatMap(\.priceAdjustments).first { $0.itemNumber == "9000003" })
        let object = try JSONSerialization.jsonObject(with: AnalyticsJSON.encode(sparse)) as! [String: Any]
        #expect(object.count == 11)
        #expect(object["adjustmentDate"] is NSNull)
        #expect(object["sourcePurchaseId"] is NSNull)
        let receipt = try JSONSerialization.jsonObject(with: AnalyticsJSON.encode(dataset.receipts[0])) as! [String: Any]
        #expect(Set(receipt.keys) == ["id", "sourceType", "identifierKind", "purchaseDate", "warehouse", "items"])
    }

    @Test("IDs do not depend on SQLite row IDs or row order")
    func stableAcrossResync() throws {
        var snapshot = try Fixtures.sourceSnapshot()
        let ids = try AnalyticsIDDeriver(idKey: Fixtures.idKey)
        let first = AnalyticsExportBuilder.build(snapshot, ids: ids)
        // Simulate CostcoTracker re-syncing receipts: items deleted and re-inserted with new rowids.
        snapshot.items = snapshot.items.map { var row = $0; row.rowID += 1000; return row }
        snapshot.receipts.reverse()
        snapshot.returns.reverse()
        let second = AnalyticsExportBuilder.build(snapshot, ids: ids)
        #expect(sameCollections(try exportCollections(first), try exportCollections(second)))
    }

    @Test("Inconsistent transactions are left out whole rather than guessed")
    func inconsistentTransaction() throws {
        let ids = try AnalyticsIDDeriver(idKey: Fixtures.idKey)
        let dataset = try build()
        #expect(!dataset.transactions.contains { $0.transactionId == ids.transactionID(transactionBarcode: "99990000000000000103") })
        #expect(dataset.exclusions[.transactionInconsistent] == 2)
    }

    @Test("Calendar dates and cents helpers")
    func helpers() {
        #expect(AnalyticsExportBuilder.calendarDate("2024-02-29") == "2024-02-29")
        #expect(AnalyticsExportBuilder.calendarDate("2026-02-29") == nil)
        #expect(AnalyticsExportBuilder.calendarDate("2026-1-01") == nil)
        #expect(AnalyticsExportBuilder.calendarDate("01/04/2026") == nil)
        #expect(AnalyticsExportBuilder.wholeCents(21.99 * 100) == 2199)
        #expect(AnalyticsExportBuilder.wholeCents(-66.5 * 100) == -6650)
        #expect(AnalyticsExportBuilder.wholeCents(.nan) == nil)
        #expect(AnalyticsExportBuilder.text("   ") == nil)
    }
}

@Suite("SQLite snapshot reader")
struct SourceSnapshotReaderTests {

    /// The exact CREATE TABLE statements from DBManager.openDatabase.
    static let schema = [
        "CREATE TABLE IF NOT EXISTS receipts (barcode TEXT PRIMARY KEY, date TEXT, warehouse TEXT);",
        "CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY AUTOINCREMENT, receipt_barcode TEXT, item_number TEXT, description TEXT, unit_price REAL, quantity REAL);",
        "CREATE TABLE IF NOT EXISTS price_adjustments (id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_barcode TEXT NOT NULL, item_number TEXT NOT NULL, adjustment_date TEXT, warehouse TEXT, adjustment_amount REAL NOT NULL, adjusted_quantity REAL, reference_line_number TEXT, transaction_type TEXT, transaction_total REAL, UNIQUE(transaction_barcode, item_number));",
        "CREATE TABLE IF NOT EXISTS item_returns (id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_barcode TEXT NOT NULL, item_number TEXT NOT NULL, return_date TEXT, warehouse TEXT, returned_quantity REAL NOT NULL, description TEXT, transaction_type TEXT, merchandise_amount REAL, transaction_total REAL, UNIQUE(transaction_barcode, item_number));",
    ]

    @Test("Schema copy matches DBManager.swift (drift guard)")
    func schemaMatchesApp() throws {
        let source = try String(contentsOf: Fixtures.repoRoot.appendingPathComponent("CostcoTracker/DBManager.swift"), encoding: .utf8)
        for statement in Self.schema {
            #expect(source.contains(statement), "DBManager schema changed; update the analytics reader")
        }
    }

    @Test("Reads the fixture rows back exactly from a real SQLite database")
    func roundTrip() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for statement in Self.schema { #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK) }

        let expected = try Fixtures.sourceSnapshot()
        func bind(_ s: OpaquePointer?, _ i: Int32, _ value: Any?) {
            switch value {
            case let v as String: sqlite3_bind_text(s, i, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let v as Double: sqlite3_bind_double(s, i, v)
            case let v as Int64: sqlite3_bind_int64(s, i, v)
            default: sqlite3_bind_null(s, i)
            }
        }
        func insert(_ sql: String, _ values: [Any?]) {
            var s: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK)
            for (i, v) in values.enumerated() { bind(s, Int32(i + 1), v) }
            #expect(sqlite3_step(s) == SQLITE_DONE)
            sqlite3_finalize(s)
        }
        for r in expected.receipts { insert("INSERT INTO receipts VALUES (?, ?, ?)", [r.barcode, r.date, r.warehouse]) }
        for r in expected.items {
            insert("INSERT INTO items VALUES (?, ?, ?, ?, ?, ?)", [r.rowID, r.receiptBarcode, r.itemNumber, r.description, r.unitPrice, r.quantity])
        }
        for r in expected.returns {
            insert("INSERT INTO item_returns VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
                r.rowID, r.transactionBarcode, r.itemNumber, r.returnDate, r.warehouse, r.returnedQuantity,
                r.description, r.transactionType, r.merchandiseAmount, r.transactionTotal,
            ])
        }
        for r in expected.priceAdjustments {
            insert("INSERT INTO price_adjustments VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
                r.rowID, r.transactionBarcode, r.itemNumber, r.adjustmentDate, r.warehouse, r.adjustmentAmount,
                r.adjustedQuantity, r.referenceLineNumber, r.transactionType, r.transactionTotal,
            ])
        }

        let snapshot = try SourceSnapshotReader.read(database: db)
        #expect(snapshot.receipts.sorted { ($0.barcode ?? "") < ($1.barcode ?? "") } == expected.receipts.sorted { ($0.barcode ?? "") < ($1.barcode ?? "") })
        #expect(snapshot.items == expected.items)
        #expect(snapshot.returns == expected.returns)
        #expect(snapshot.priceAdjustments == expected.priceAdjustments)
        #expect(sqlite3_get_autocommit(db) != 0) // left no transaction open

        // And the database path produces the same export as the fixture path.
        let ids = try AnalyticsIDDeriver(idKey: Fixtures.idKey)
        #expect(sameCollections(
            try exportCollections(AnalyticsExportBuilder.build(snapshot, ids: ids)),
            try exportCollections(AnalyticsExportBuilder.build(expected, ids: ids))
        ))
    }

    @Test("Fails cleanly without a database")
    func noDatabase() {
        #expect(throws: SourceSnapshotError.databaseUnavailable) { try SourceSnapshotReader.read(database: nil) }
    }
}
