import Foundation
import Testing
@testable import AnalyticsSync

@Suite("Batch planner")
struct BatchPlannerTests {

    private func units(_ snapshot: SourceSnapshot? = nil) throws -> [AnalyticsUploadUnit] {
        let dataset = AnalyticsExportBuilder.build(try snapshot ?? Fixtures.sourceSnapshot(), ids: try AnalyticsIDDeriver(idKey: Fixtures.idKey))
        var exclusions = dataset.exclusions
        return try AnalyticsBatchPlanner.units(for: dataset, exclusions: &exclusions)
    }

    private func plan(
        _ units: [AnalyticsUploadUnit],
        _ mode: AnalyticsSyncMode,
        uploaded: [String: String] = [:],
        exclusions: [AnalyticsExclusionReason: Int] = [:]
    ) throws -> AnalyticsUploadPlan {
        try AnalyticsBatchPlanner.plan(
            units: units, mode: mode, exclusions: exclusions, uploadedHashes: uploaded, requestId: nil,
            runId: AnalyticsBatchPlanner.newRunID(), exportedAt: "2026-11-01T12:00:00Z", now: Date()
        )
    }

    @Test("Full plan sends every unit with a manifest of every ID")
    func fullPlan() throws {
        let units = try units()
        let plan = try plan(units, .full)
        let manifest = try #require(plan.manifest)
        #expect(manifest.receiptIds.count == 5)
        #expect(manifest.returnIds.count == 4)
        #expect(manifest.priceAdjustmentIds.count == 3)
        #expect(plan.rowCount == 5 + 9 + 4 + 3)
        #expect(plan.replacesHashCache)
        #expect(plan.unitHashes.count == units.count)
    }

    @Test("Incremental plan sends only changed units and no manifest")
    func incrementalPlan() throws {
        let original = try units()
        let uploaded = Dictionary(uniqueKeysWithValues: original.map { ($0.key, $0.hash) })
        #expect(try plan(original, .incremental, uploaded: uploaded).batches.isEmpty)

        var snapshot = try Fixtures.sourceSnapshot()
        snapshot.items[0].unitPrice = 20.99 // one receipt changed
        let changed = try plan(try units(snapshot), .incremental, uploaded: uploaded)
        #expect(changed.manifest == nil)
        #expect(changed.batches.count == 1)
        #expect(changed.unitHashes.count == 1)
        let batch = try JSONSerialization.jsonObject(with: changed.batches[0]) as! [String: [Any]]
        #expect(batch["receipts"]?.count == 1)
        #expect(batch["returns"]?.isEmpty == true)
    }

    @Test("Batches respect the 200-row limit and keep receipts and transactions whole")
    func batchLimits() throws {
        var snapshot = SourceSnapshot()
        for r in 0..<30 {
            let barcode = String(format: "9999%016d", r)
            snapshot.receipts.append(SourceReceiptRow(barcode: barcode, date: "2026-01-01", warehouse: "SYNTHETIC"))
            for i in 0..<15 {
                snapshot.items.append(SourceItemRow(rowID: Int64(r * 100 + i), receiptBarcode: barcode, itemNumber: "\(9_000_000 + i)", description: "SYNTHETIC", unitPrice: 1, quantity: 1))
            }
        }
        let plan = try plan(try units(snapshot), .full)
        #expect(plan.batches.count > 1)
        var receiptsSeen = 0
        for body in plan.batches {
            #expect(body.count <= AnalyticsBatchPlanner.maxBatchBytes)
            let batch = try JSONSerialization.jsonObject(with: body) as! [String: [[String: Any]]]
            let rows = batch["receipts"]!.reduce(0) { $0 + 1 + ($1["items"] as! [Any]).count }
            #expect(rows <= 200)
            for receipt in batch["receipts"]! { #expect((receipt["items"] as! [Any]).count == 15) }
            receiptsSeen += batch["receipts"]!.count
        }
        #expect(receiptsSeen == 30)
    }

    @Test("A receipt too large for any batch is excluded and reported, not split")
    func oversizedUnit() throws {
        var snapshot = SourceSnapshot()
        snapshot.receipts = [SourceReceiptRow(barcode: "99990000000000000777", date: nil, warehouse: nil)]
        snapshot.items = (0..<250).map {
            SourceItemRow(rowID: Int64($0), receiptBarcode: "99990000000000000777", itemNumber: "\($0)", description: "", unitPrice: 1, quantity: 1)
        }
        let dataset = AnalyticsExportBuilder.build(snapshot, ids: try AnalyticsIDDeriver(idKey: Fixtures.idKey))
        var exclusions = dataset.exclusions
        let units = try AnalyticsBatchPlanner.units(for: dataset, exclusions: &exclusions)
        #expect(units.isEmpty)
        #expect(exclusions[.unitTooLarge] == 251)
    }

    @Test("Full plans are refused while any existing record is excluded; incremental plans are not")
    func fullPlanRefusedWhenRecordsHidden() throws {
        let units = try units()
        for reason in AnalyticsExclusionReason.allCases where reason.hidesExistingRecordFromManifest {
            #expect(throws: AnalyticsPlanError.fullSyncBlocked(rows: 3)) {
                try plan(units, .full, exclusions: [reason: 3])
            }
            #expect(try plan(units, .incremental, exclusions: [reason: 3]).manifest == nil)
        }
        let harmless: [AnalyticsExclusionReason: Int] = [
            .itemOrphan: 1, .itemInvalidQuantity: 1, .itemMissingItemNumber: 1, .itemInvalidPrice: 1,
            .receiptMissingKey: 1, .returnMissingKey: 1, .adjustmentMissingKey: 1,
        ]
        #expect(try plan(units, .full, exclusions: harmless).manifest != nil)
        #expect(throws: AnalyticsPlanError.fullSyncBlocked(rows: 7)) {
            try plan(units, .full, exclusions: harmless.merging([.unitTooLarge: 5, .transactionInconsistent: 2]) { a, _ in a })
        }
    }

    @Test("Batch bodies are deterministic for identical input")
    func deterministic() throws {
        let a = try plan(try units(), .full)
        let b = try plan(try units(), .full)
        #expect(a.batches == b.batches)
    }

    @Test("Run IDs are lower-case UUIDs; timestamps are zoned ISO-8601")
    func formats() {
        let id = AnalyticsBatchPlanner.newRunID()
        #expect(id == id.lowercased())
        #expect(UUID(uuidString: id) != nil)
        #expect(AnalyticsBatchPlanner.timestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    }
}
