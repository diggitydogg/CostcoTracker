import CryptoKit
import Foundation

// MARK: - Upload units, batches and plans
//
// The sync protocol requires each receipt to travel with all of its items, and
// each return/adjustment transaction to travel whole. Those are the "units".
// Units are packed into numbered batches within the server's limits
// (≤ 200 rows, ≤ 256 KiB per body; a safety margin is kept below the byte
// limit). Each unit carries a content hash so an incremental sync only sends
// units that changed since the last successful upload.

nonisolated enum AnalyticsSyncMode: String, Codable, Sendable {
    case incremental
    case full
}

nonisolated struct AnalyticsUploadUnit: Sendable {
    enum Content: Sendable {
        case receipt(AnalyticsReceiptBundle)
        case transaction(AnalyticsTransactionGroup)
    }

    /// Receipt ID or transaction ID — stable and opaque.
    var key: String
    var content: Content
    var rowCount: Int
    var encodedSize: Int
    /// SHA-256 of the unit's canonical JSON.
    var hash: String
}

nonisolated struct AnalyticsManifest: Codable, Equatable, Sendable {
    var receiptIds: [String]
    var returnIds: [String]
    var priceAdjustmentIds: [String]
}

/// Everything needed to send (or resume) one sync run. Batch bodies are stored
/// as the exact bytes to send, so a resent batch is identical and the server's
/// idempotent replay applies.
nonisolated struct AnalyticsUploadPlan: Codable, Sendable {
    var runId: String
    var mode: AnalyticsSyncMode
    var requestId: String?
    var exportedAt: String
    var batches: [Data]
    var manifest: AnalyticsManifest?
    /// Hashes to record as uploaded once the run completes.
    var unitHashes: [String: String]
    /// For full runs the uploaded-hash cache is replaced, not merged.
    var replacesHashCache: Bool
    var rowCount: Int
    var createdAt: Date
}

nonisolated enum AnalyticsBatchPlanner {

    static let maxRowsPerBatch = 200
    /// Server limit is 256 KiB; keep headroom for the JSON envelope.
    static let maxBatchBytes = 240_000

    private struct TransactionBody: Encodable {
        var returns: [AnalyticsReturn]
        var priceAdjustments: [AnalyticsPriceAdjustment]
    }

    /// Converts a dataset into upload units. Units that can never fit in a
    /// batch are dropped and reported (rows, by reason) via `exclusions`.
    static func units(
        for dataset: AnalyticsDataset,
        exclusions: inout [AnalyticsExclusionReason: Int]
    ) throws -> [AnalyticsUploadUnit] {
        var units: [AnalyticsUploadUnit] = []
        for bundle in dataset.receipts {
            let data = try AnalyticsJSON.encode(bundle)
            units.append(
                AnalyticsUploadUnit(
                    key: bundle.receipt.id,
                    content: .receipt(bundle),
                    rowCount: 1 + bundle.items.count,
                    encodedSize: data.count,
                    hash: sha256Hex(data)
                )
            )
        }
        for group in dataset.transactions {
            let data = try AnalyticsJSON.encode(TransactionBody(returns: group.returns, priceAdjustments: group.priceAdjustments))
            units.append(
                AnalyticsUploadUnit(
                    key: group.transactionId,
                    content: .transaction(group),
                    rowCount: group.rowCount,
                    encodedSize: data.count,
                    hash: sha256Hex(data)
                )
            )
        }
        return units.filter { unit in
            let fits = unit.rowCount <= maxRowsPerBatch && unit.encodedSize + 128 <= maxBatchBytes
            if !fits { exclusions[.unitTooLarge, default: 0] += unit.rowCount }
            return fits
        }
    }

    /// Builds a run plan.
    /// - incremental: only units whose hash differs from `uploadedHashes`.
    /// - full: every unit, plus the manifest of every record ID, so the server
    ///   can reconcile (and hold back large removals for owner review).
    static func plan(
        units: [AnalyticsUploadUnit],
        mode: AnalyticsSyncMode,
        uploadedHashes: [String: String],
        requestId: String?,
        runId: String,
        exportedAt: String,
        now: Date
    ) throws -> AnalyticsUploadPlan {
        let selected = mode == .full ? units : units.filter { uploadedHashes[$0.key] != $0.hash }

        var batches: [Data] = []
        var current = AnalyticsSyncBatch(receipts: [], returns: [], priceAdjustments: [])
        var currentRows = 0
        var currentBytes = 64

        func flush() throws {
            guard currentRows > 0 else { return }
            batches.append(try AnalyticsJSON.encode(current))
            current = AnalyticsSyncBatch(receipts: [], returns: [], priceAdjustments: [])
            currentRows = 0
            currentBytes = 64
        }

        for unit in selected {
            if currentRows + unit.rowCount > maxRowsPerBatch || currentBytes + unit.encodedSize + 8 > maxBatchBytes {
                try flush()
            }
            switch unit.content {
            case .receipt(let bundle):
                current.receipts.append(bundle)
            case .transaction(let group):
                current.returns.append(contentsOf: group.returns)
                current.priceAdjustments.append(contentsOf: group.priceAdjustments)
            }
            currentRows += unit.rowCount
            currentBytes += unit.encodedSize + 8
        }
        try flush()

        var manifest: AnalyticsManifest?
        if mode == .full {
            var receiptIds: [String] = []
            var returnIds: [String] = []
            var adjustmentIds: [String] = []
            for unit in units {
                switch unit.content {
                case .receipt(let bundle):
                    receiptIds.append(bundle.receipt.id)
                case .transaction(let group):
                    returnIds.append(contentsOf: group.returns.map(\.id))
                    adjustmentIds.append(contentsOf: group.priceAdjustments.map(\.id))
                }
            }
            manifest = AnalyticsManifest(receiptIds: receiptIds, returnIds: returnIds, priceAdjustmentIds: adjustmentIds)
        }

        return AnalyticsUploadPlan(
            runId: runId,
            mode: mode,
            requestId: requestId,
            exportedAt: exportedAt,
            batches: batches,
            manifest: manifest,
            unitHashes: Dictionary(selected.map { ($0.key, $0.hash) }, uniquingKeysWith: { first, _ in first }),
            replacesHashCache: mode == .full,
            rowCount: selected.reduce(0) { $0 + $1.rowCount },
            createdAt: now
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lower-case UUID v4, the run ID format the server accepts.
    static func newRunID() -> String {
        UUID().uuidString.lowercased()
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
