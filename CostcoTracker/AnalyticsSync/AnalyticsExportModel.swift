import Foundation

// MARK: - Analytics Export V1 records (as sent to CostcoTracker Analytics)
//
// Field names and semantics follow ANALYTICS_DATA_CONTRACT.md in the
// CostcoTracker Analytics repository. Every field is always encoded, with an
// explicit JSON null when unknown (never omitted, never "").

nonisolated enum AnalyticsFormat {
    static let format = "costcotracker-analytics"
    static let version = 1
    static let currency = "USD"
}

nonisolated enum AnalyticsSourceType: String, Codable, Sendable {
    case warehouse, online, synthetic
}

nonisolated enum AnalyticsIdentifierKind: String, Codable, Sendable {
    case transactionBarcode, synthesizedWarehouseKey, onlineOrderKey, synthetic
}

nonisolated struct AnalyticsReceipt: Encodable, Equatable, Sendable {
    var id: String
    var sourceType: AnalyticsSourceType
    var identifierKind: AnalyticsIdentifierKind
    var purchaseDate: String?
    var warehouse: String?

    private enum CodingKeys: String, CodingKey { case id, sourceType, identifierKind, purchaseDate, warehouse }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceType, forKey: .sourceType)
        try c.encode(identifierKind, forKey: .identifierKind)
        try c.encode(purchaseDate, forKey: .purchaseDate)
        try c.encode(warehouse, forKey: .warehouse)
    }
}

/// An item as carried inside a receipt bundle (no `purchaseId`; the bundle's receipt is the purchase).
nonisolated struct AnalyticsItem: Encodable, Equatable, Sendable {
    var id: String
    var itemNumber: String
    var description: String
    var quantity: Double
    var lineTotalCents: Int
    var unitPriceCents: Int?

    private enum CodingKeys: String, CodingKey { case id, itemNumber, description, quantity, lineTotalCents, unitPriceCents }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(itemNumber, forKey: .itemNumber)
        try c.encode(description, forKey: .description)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(lineTotalCents, forKey: .lineTotalCents)
        try c.encode(unitPriceCents, forKey: .unitPriceCents)
    }
}

/// A receipt with its complete item set — the unit the sync protocol replaces atomically.
nonisolated struct AnalyticsReceiptBundle: Encodable, Equatable, Sendable {
    var receipt: AnalyticsReceipt
    var items: [AnalyticsItem]

    private enum CodingKeys: String, CodingKey { case id, sourceType, identifierKind, purchaseDate, warehouse, items }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(receipt.id, forKey: .id)
        try c.encode(receipt.sourceType, forKey: .sourceType)
        try c.encode(receipt.identifierKind, forKey: .identifierKind)
        try c.encode(receipt.purchaseDate, forKey: .purchaseDate)
        try c.encode(receipt.warehouse, forKey: .warehouse)
        try c.encode(items, forKey: .items)
    }
}

nonisolated struct AnalyticsReturn: Encodable, Equatable, Sendable {
    var id: String
    var transactionId: String
    var itemNumber: String
    var returnDate: String?
    var warehouse: String?
    var quantity: Double
    var description: String?
    var transactionType: String?
    var merchandiseAmountCents: Int?
    var transactionTotalCents: Int?
    /// Always nil: the iOS database does not know which purchase a return came from.
    var sourcePurchaseId: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, transactionId, itemNumber, returnDate, warehouse, quantity, description
        case transactionType, merchandiseAmountCents, transactionTotalCents, sourcePurchaseId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(transactionId, forKey: .transactionId)
        try c.encode(itemNumber, forKey: .itemNumber)
        try c.encode(returnDate, forKey: .returnDate)
        try c.encode(warehouse, forKey: .warehouse)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(description, forKey: .description)
        try c.encode(transactionType, forKey: .transactionType)
        try c.encode(merchandiseAmountCents, forKey: .merchandiseAmountCents)
        try c.encode(transactionTotalCents, forKey: .transactionTotalCents)
        try c.encode(sourcePurchaseId, forKey: .sourcePurchaseId)
    }
}

nonisolated struct AnalyticsPriceAdjustment: Encodable, Equatable, Sendable {
    var id: String
    var transactionId: String
    var itemNumber: String
    var adjustmentDate: String?
    var warehouse: String?
    var amountCents: Int
    var adjustedQuantity: Double?
    var referenceLineNumbers: [String]
    var transactionType: String?
    var transactionTotalCents: Int
    /// Always nil: the iOS database does not record which purchase was adjusted.
    var sourcePurchaseId: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, transactionId, itemNumber, adjustmentDate, warehouse, amountCents, adjustedQuantity
        case referenceLineNumbers, transactionType, transactionTotalCents, sourcePurchaseId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(transactionId, forKey: .transactionId)
        try c.encode(itemNumber, forKey: .itemNumber)
        try c.encode(adjustmentDate, forKey: .adjustmentDate)
        try c.encode(warehouse, forKey: .warehouse)
        try c.encode(amountCents, forKey: .amountCents)
        try c.encode(adjustedQuantity, forKey: .adjustedQuantity)
        try c.encode(referenceLineNumbers, forKey: .referenceLineNumbers)
        try c.encode(transactionType, forKey: .transactionType)
        try c.encode(transactionTotalCents, forKey: .transactionTotalCents)
        try c.encode(sourcePurchaseId, forKey: .sourcePurchaseId)
    }
}

/// All rows of one return/adjustment transaction. The server requires a
/// transaction's rows to travel together, and `transactionTotalCents` is a
/// whole-transaction value repeated on each row (never summed by this app).
nonisolated struct AnalyticsTransactionGroup: Equatable, Sendable {
    var transactionId: String
    var returns: [AnalyticsReturn]
    var priceAdjustments: [AnalyticsPriceAdjustment]

    var rowCount: Int { returns.count + priceAdjustments.count }
}

/// Why a source row was left out of the export. Reasons carry no values.
nonisolated enum AnalyticsExclusionReason: String, CaseIterable, Sendable {
    case receiptMissingKey = "receipt.missingKey"
    case itemOrphan = "item.orphan"
    case itemMissingItemNumber = "item.missingItemNumber"
    case itemInvalidQuantity = "item.invalidQuantity"
    case itemInvalidPrice = "item.invalidPrice"
    case returnMissingKey = "return.missingKey"
    case returnInvalidQuantity = "return.invalidQuantity"
    case returnInvalidAmount = "return.invalidAmount"
    case adjustmentMissingKey = "adjustment.missingKey"
    case adjustmentInvalidAmount = "adjustment.invalidAmount"
    case adjustmentMissingTransactionTotal = "adjustment.missingTransactionTotal"
    case transactionInconsistent = "transaction.inconsistent"
    case unitTooLarge = "upload.unitTooLarge"
}

/// The complete in-memory Analytics dataset built from the local database.
nonisolated struct AnalyticsDataset: Sendable {
    var receipts: [AnalyticsReceiptBundle]
    var transactions: [AnalyticsTransactionGroup]
    var exclusions: [AnalyticsExclusionReason: Int]

    var receiptCount: Int { receipts.count }
    var itemCount: Int { receipts.reduce(0) { $0 + $1.items.count } }
    var returnCount: Int { transactions.reduce(0) { $0 + $1.returns.count } }
    var priceAdjustmentCount: Int { transactions.reduce(0) { $0 + $1.priceAdjustments.count } }
    var excludedCount: Int { exclusions.values.reduce(0, +) }
}

/// One protocol batch body: `PUT /api/sync/runs/:runId/batches/:seq`.
nonisolated struct AnalyticsSyncBatch: Encodable, Sendable {
    var receipts: [AnalyticsReceiptBundle]
    var returns: [AnalyticsReturn]
    var priceAdjustments: [AnalyticsPriceAdjustment]

    var rowCount: Int {
        receipts.reduce(0) { $0 + 1 + $1.items.count } + returns.count + priceAdjustments.count
    }
}

nonisolated enum AnalyticsJSON {
    /// Deterministic JSON: sorted keys, no escaped slashes. Used for batch
    /// bodies (so a resent batch is byte-identical) and for change detection.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
