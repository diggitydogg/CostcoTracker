import CryptoKit
import Foundation
import Testing
@testable import AnalyticsSync

@Suite("Deterministic export IDs")
struct IDDerivationTests {

    @Test("Match the independently generated test vectors (Node crypto HMAC-SHA256)")
    func vectors() throws {
        let file = try Fixtures.json("id-vectors.json")
        let ids = try AnalyticsIDDeriver(idKey: file["idKey"] as! String)
        let vectors = file["vectors"] as! [[String: Any]]
        #expect(vectors.count >= 9)
        for vector in vectors {
            let parts = vector["parts"] as! [String]
            let expected = vector["expected"] as! String
            let actual: String
            switch vector["kind"] as! String {
            case "receipt": actual = ids.receiptID(barcode: parts[0])
            case "item": actual = ids.itemID(receiptBarcode: parts[0], itemNumber: parts[1], occurrence: Int(parts[2])!)
            case "return": actual = ids.returnID(transactionBarcode: parts[0], itemNumber: parts[1])
            case "adjustment": actual = ids.adjustmentID(transactionBarcode: parts[0], itemNumber: parts[1])
            case "transaction": actual = ids.transactionID(transactionBarcode: parts[0])
            default: Issue.record("unknown kind"); continue
            }
            #expect(actual == expected, "\(vector["kind"]!) \(parts)")
        }
    }

    @Test("Uses the 32 decoded key bytes and a NUL-separated UTF-8 message")
    func rawHMAC() throws {
        let file = try Fixtures.json("id-vectors.json")
        let raw = file["rawHmac"] as! [String: String]
        let key = AnalyticsIDDeriver.decodeBase64URL(file["idKey"] as! String)!
        #expect(key.count == 32)
        #expect(key.map { String(format: "%02x", $0) }.joined() == file["hmacKeyHex"] as! String)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(raw["message"]!.utf8), using: SymmetricKey(data: key))
        #expect(AnalyticsIDDeriver.encodeBase64URL(Data(mac)) == raw["base64url"])
        let ids = try AnalyticsIDDeriver(idKey: file["idKey"] as! String)
        #expect(ids.token("receipt", ["abc"]) == String(raw["base64url"]!.prefix(22)))
    }

    @Test("IDs are stable, namespaced and never contain the source key")
    func stableAndNamespaced() throws {
        let a = try AnalyticsIDDeriver(idKey: Fixtures.idKey)
        let b = try AnalyticsIDDeriver(idKey: Fixtures.idKey)
        let barcode = "99990000000000000101"
        #expect(a.receiptID(barcode: barcode) == b.receiptID(barcode: barcode))
        #expect(a.receiptID(barcode: barcode).hasPrefix("r_"))
        #expect(a.transactionID(transactionBarcode: barcode).hasPrefix("t_"))
        // Same source key in different namespaces never produces the same token.
        #expect(a.receiptID(barcode: barcode).dropFirst(2) != a.transactionID(transactionBarcode: barcode).dropFirst(2))
        #expect(a.returnID(transactionBarcode: barcode, itemNumber: "1").dropFirst(4) != a.adjustmentID(transactionBarcode: barcode, itemNumber: "1").dropFirst(4))
        for id in [a.receiptID(barcode: barcode), a.transactionID(transactionBarcode: barcode)] {
            #expect(!id.contains(barcode))
            #expect(id.count == 24) // 2-character prefix + 22-character token
        }
        // Separator prevents ambiguity between ("ab","c") and ("a","bc").
        #expect(a.returnID(transactionBarcode: "ab", itemNumber: "c") != a.returnID(transactionBarcode: "a", itemNumber: "bc"))
        // Item occurrence distinguishes repeated item numbers on one online order.
        #expect(a.itemID(receiptBarcode: "o", itemNumber: "1", occurrence: 0) != a.itemID(receiptBarcode: "o", itemNumber: "1", occurrence: 1))
    }

    @Test("A different idKey yields different IDs")
    func keyDependence() throws {
        let other = AnalyticsIDDeriver.encodeBase64URL(Data(repeating: 7, count: 32))
        #expect(try AnalyticsIDDeriver(idKey: Fixtures.idKey).receiptID(barcode: "x") != AnalyticsIDDeriver(idKey: other).receiptID(barcode: "x"))
    }

    @Test("Rejects malformed or short keys", arguments: ["", "not base64!", "AAEC", String(repeating: "A", count: 44)])
    func invalidKeys(_ key: String) {
        #expect(throws: AnalyticsIDError.invalidIDKey) { try AnalyticsIDDeriver(idKey: key) }
    }
}
