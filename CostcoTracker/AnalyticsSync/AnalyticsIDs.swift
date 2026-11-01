import CryptoKit
import Foundation

// MARK: - Analytics Export V1 record IDs
//
// Every record sent to CostcoTracker Analytics gets a deterministic, opaque ID
// derived from its real source key and the server-issued `idKey`:
//
//   token(domain, part1, part2, …) =
//       first 22 characters of base64url( HMAC-SHA256( key, domain ␀ part1 ␀ part2 … ) )
//
// where `key` is the 32 raw bytes decoded from the base64url `idKey`, ␀ is a
// single NUL (U+0000) separator, and the message is UTF-8.
//
//   receipt      "r_"   + token("receipt",     receipts.barcode)
//   item         "i_"   + token("item",        items.receipt_barcode, items.item_number, occurrence)
//   return       "ret_" + token("return",      item_returns.transaction_barcode, item_returns.item_number)
//   adjustment   "adj_" + token("adjustment",  price_adjustments.transaction_barcode, price_adjustments.item_number)
//   transaction  "t_"   + token("transaction", transaction_barcode)
//
// `occurrence` is the 0-based decimal index of the item row among rows of the
// same receipt with the same item number, ordered by SQLite rowid (always "0"
// for warehouse receipts, which store one row per item number).
//
// The source keys (real receipt barcodes, synthetic WHSE_ keys, online order
// keys) never leave the device; only these tokens do. The distinct domains keep
// receipt IDs and transaction IDs in separate namespaces, so a return can never
// be joined to a purchase by ID. SQLite row IDs are never used for identity.
// See docs/ANALYTICS_CLOUD_SYNC.md for test vectors.

nonisolated enum AnalyticsIDError: Error, Equatable {
    case invalidIDKey
}

nonisolated struct AnalyticsIDDeriver: Sendable {

    private let key: SymmetricKey

    /// - Parameter idKey: the server-issued base64url key; must decode to 32 bytes.
    init(idKey: String) throws {
        guard let bytes = Self.decodeBase64URL(idKey), bytes.count == 32 else {
            throw AnalyticsIDError.invalidIDKey
        }
        key = SymmetricKey(data: bytes)
    }

    func token(_ domain: String, _ parts: [String]) -> String {
        let message = ([domain] + parts).joined(separator: "\u{0}")
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return String(Self.encodeBase64URL(Data(mac)).prefix(22))
    }

    func receiptID(barcode: String) -> String {
        "r_" + token("receipt", [barcode])
    }

    func itemID(receiptBarcode: String, itemNumber: String, occurrence: Int) -> String {
        "i_" + token("item", [receiptBarcode, itemNumber, String(occurrence)])
    }

    func returnID(transactionBarcode: String, itemNumber: String) -> String {
        "ret_" + token("return", [transactionBarcode, itemNumber])
    }

    func adjustmentID(transactionBarcode: String, itemNumber: String) -> String {
        "adj_" + token("adjustment", [transactionBarcode, itemNumber])
    }

    func transactionID(transactionBarcode: String) -> String {
        "t_" + token("transaction", [transactionBarcode])
    }

    // MARK: base64url

    static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ text: String) -> Data? {
        guard !text.isEmpty,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
