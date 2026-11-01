import CryptoKit
import Foundation
@testable import AnalyticsSync

// MARK: - Fixtures

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Same key as id-vectors.json: bytes 0x00…0x1f.
    static let idKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    static func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func sourceSnapshot() throws -> SourceSnapshot {
        let root = try json("source-snapshot.json")
        func rows(_ key: String) -> [[String: Any]] { root[key] as! [[String: Any]] }
        func str(_ row: [String: Any], _ key: String) -> String? { row[key] as? String }
        func dbl(_ row: [String: Any], _ key: String) -> Double? { (row[key] as? NSNumber)?.doubleValue }
        func id(_ row: [String: Any]) -> Int64 { (row["id"] as! NSNumber).int64Value }

        return SourceSnapshot(
            receipts: rows("receipts").map { SourceReceiptRow(barcode: str($0, "barcode"), date: str($0, "date"), warehouse: str($0, "warehouse")) },
            items: rows("items").map {
                SourceItemRow(
                    rowID: id($0), receiptBarcode: str($0, "receipt_barcode"), itemNumber: str($0, "item_number"),
                    description: str($0, "description"), unitPrice: dbl($0, "unit_price"), quantity: dbl($0, "quantity")
                )
            },
            returns: rows("item_returns").map {
                SourceReturnRow(
                    rowID: id($0), transactionBarcode: str($0, "transaction_barcode"), itemNumber: str($0, "item_number"),
                    returnDate: str($0, "return_date"), warehouse: str($0, "warehouse"), returnedQuantity: dbl($0, "returned_quantity"),
                    description: str($0, "description"), transactionType: str($0, "transaction_type"),
                    merchandiseAmount: dbl($0, "merchandise_amount"), transactionTotal: dbl($0, "transaction_total")
                )
            },
            priceAdjustments: rows("price_adjustments").map {
                SourcePriceAdjustmentRow(
                    rowID: id($0), transactionBarcode: str($0, "transaction_barcode"), itemNumber: str($0, "item_number"),
                    adjustmentDate: str($0, "adjustment_date"), warehouse: str($0, "warehouse"),
                    adjustmentAmount: dbl($0, "adjustment_amount"), adjustedQuantity: dbl($0, "adjusted_quantity"),
                    referenceLineNumber: str($0, "reference_line_number"), transactionType: str($0, "transaction_type"),
                    transactionTotal: dbl($0, "transaction_total")
                )
            }
        )
    }

    /// Every raw source key in the fixture; none may ever appear in an upload.
    static func rawSourceKeys() throws -> [String] {
        let s = try sourceSnapshot()
        let keys = s.receipts.compactMap(\.barcode) + s.returns.compactMap(\.transactionBarcode)
            + s.priceAdjustments.compactMap(\.transactionBarcode)
        return Array(Set(keys.filter { !$0.isEmpty }))
    }
}

/// Flattens a dataset into Export V1 collections (items regain `purchaseId`) as JSON objects.
func exportCollections(_ dataset: AnalyticsDataset) throws -> [String: [[String: Any]]] {
    func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: AnalyticsJSON.encode(value)) as! [String: Any]
    }
    var receipts: [[String: Any]] = []
    var items: [[String: Any]] = []
    for bundle in dataset.receipts {
        receipts.append(try object(bundle.receipt))
        for item in bundle.items {
            var dict = try object(item)
            dict["purchaseId"] = bundle.receipt.id
            items.append(dict)
        }
    }
    let returns = try dataset.transactions.flatMap { try $0.returns.map(object) }
    let adjustments = try dataset.transactions.flatMap { try $0.priceAdjustments.map(object) }
    let byId: ([String: Any], [String: Any]) -> Bool = { ($0["id"] as! String) < ($1["id"] as! String) }
    return [
        "receipts": receipts.sorted(by: byId),
        "items": items.sorted(by: byId),
        "returns": returns.sorted(by: byId),
        "priceAdjustments": adjustments.sorted(by: byId),
    ]
}

/// Structural equality of two exportCollections results (order-insensitive keys, ordered arrays).
func sameCollections(_ a: [String: [[String: Any]]], _ b: [String: [[String: Any]]]) -> Bool {
    guard Set(a.keys) == Set(b.keys) else { return false }
    for (key, rows) in a {
        guard let other = b[key], NSArray(array: rows).isEqual(to: other) else { return false }
    }
    return true
}

// MARK: - Fake Analytics server (device + sync protocol)

/// An in-memory model of the CostcoTracker Analytics device/sync API with the
/// same request shapes and semantics as the deployed backend, plus fault
/// injection. Used as the HTTP transport in coordinator/uploader tests.
final class FakeAnalyticsServer: AnalyticsHTTPTransport {

    struct Recorded {
        var method: String
        var path: String
        var authorization: String?
        var body: Data?
        var url: URL
    }

    struct Fault {
        var matches: (String, String) -> Bool
        var response: FaultResponse
        var remaining: Int
    }

    enum FaultResponse {
        case network
        case status(Int, code: String)
    }

    struct Run {
        var id: String
        var deviceId: String
        var mode: String
        var requestId: String?
        var status: String
        var batches: [Int: String] = [:]   // seq → payload hash
        var rowsSent: [String: Int] = ["receipts": 0, "returns": 0, "priceAdjustments": 0]
        var pendingRemovals: [String: Int]?
    }

    var idKey = Fixtures.idKey
    var now = Date(timeIntervalSince1970: 1_793_000_000)
    var codes: [String: Date] = [:]          // normalized code → expiry
    var usedCodes: Set<String> = []
    var devices: [String: (id: String, revoked: Bool)] = [:]  // token → device
    var syncRequests: [(id: String, status: String)] = []
    var runs: [String: Run] = [:]
    var receipts: [String: Data] = [:]
    var returns: [String: Data] = [:]
    var adjustments: [String: Data] = [:]
    var tombstoned: Set<String> = []
    var log: [Recorded] = []
    var faults: [Fault] = []
    private var deviceCounter = 0

    // MARK: Test controls

    private var codeCounter = 0

    /// Issues a one-time code (unique unless one is given), like the website does.
    func issueCode(_ code: String? = nil, validFor seconds: TimeInterval = 600) -> String {
        codeCounter += 1
        let code = code ?? String(format: "CODE%01d-%05d", codeCounter % 10, codeCounter)
        codes[normalize(code)] = now.addingTimeInterval(seconds)
        return code
    }

    func fail(_ response: FaultResponse, times: Int = 1, when matches: @escaping (String, String) -> Bool) {
        faults.append(Fault(matches: matches, response: response, remaining: times))
    }

    func revokeAllDevices() {
        for (token, device) in devices { devices[token] = (device.id, true) }
    }

    func addSyncRequest(_ id: String = "req_test1") {
        syncRequests.append((id, "pending"))
    }

    func requests(method: String, pathPrefix: String) -> [Recorded] {
        log.filter { $0.method == method && $0.path.hasPrefix(pathPrefix) }
    }

    var allUploadedBodies: Data {
        log.compactMap(\.body).reduce(Data(), +)
    }

    // MARK: Transport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        let path = url.path
        log.append(Recorded(method: method, path: path, authorization: request.value(forHTTPHeaderField: "Authorization"), body: request.httpBody, url: url))

        if let index = faults.firstIndex(where: { $0.remaining > 0 && $0.matches(method, path) }) {
            faults[index].remaining -= 1
            switch faults[index].response {
            case .network:
                throw URLError(.notConnectedToInternet)
            case .status(let status, let code):
                return respond(url, status, ["error": ["code": code, "message": "Injected failure"]])
            }
        }
        return route(method: method, path: path, url: url, request: request)
    }

    private func respond(_ url: URL, _ status: Int, _ body: Any) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: body)
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private func error(_ url: URL, _ status: Int, _ code: String, extra: [String: Any] = [:]) -> (Data, HTTPURLResponse) {
        var body: [String: Any] = ["code": code, "message": "Fake server: \(code)"]
        body.merge(extra) { _, new in new }
        return respond(url, status, ["error": body])
    }

    private func normalize(_ code: String) -> String {
        code.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
    }

    private func jsonBody(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func runJSON(_ run: Run) -> [String: Any] {
        var json: [String: Any] = [
            "id": run.id, "status": run.status, "mode": run.mode,
            "batch_count": run.batches.count, "marked_missing": 0,
        ]
        json["pendingRemovals"] = run.pendingRemovals ?? NSNull()
        return json
    }

    private func route(method: String, path: String, url: URL, request: URLRequest) -> (Data, HTTPURLResponse) {
        if method == "POST" && path == "/api/device/enroll" {
            let body = jsonBody(request)
            let code = normalize(body["code"] as? String ?? "")
            guard let expiry = codes[code], expiry > now, !usedCodes.contains(code) else {
                return error(url, 401, "invalid_code")
            }
            guard let name = body["deviceName"] as? String, !name.isEmpty, name.count <= 60 else {
                return error(url, 400, "invalid_request")
            }
            usedCodes.insert(code)
            deviceCounter += 1
            let deviceId = "dev_test\(deviceCounter)"
            let token = "token_\(deviceCounter)_" + String(repeating: "x", count: 30)
            devices[token] = (deviceId, false)
            return respond(url, 201, ["deviceId": deviceId, "deviceToken": token, "idKey": idKey])
        }

        // Everything else requires a valid, unrevoked bearer token.
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer "),
              let device = devices[String(header.dropFirst(7))], !device.revoked
        else { return error(url, 401, "unauthenticated") }

        let parts = path.split(separator: "/").map(String.init)
        func match(_ m: String, _ pattern: String) -> [String]? {
            // pattern like "api/sync/runs/:/batches/:" — ":" captures a component.
            let want = pattern.split(separator: "/").map(String.init)
            guard m == method, want.count == parts.count else { return nil }
            var captures: [String] = []
            for (w, p) in zip(want, parts) {
                if w == ":" { captures.append(p) } else if w != p { return nil }
            }
            return captures
        }

        if match("GET", "api/device/config") != nil {
            return respond(url, 200, ["deviceId": device.id, "idKey": idKey, "formatVersion": 1, "limits": ["maxRowsPerBatch": 200]])

        }
        if match("GET", "api/device/sync-requests") != nil {
            let open = syncRequests.filter { $0.status == "pending" || $0.status == "acknowledged" }
            return respond(url, 200, ["requests": open.map { ["id": $0.id, "requested_at": "2026-11-01T12:00:00.000Z", "status": $0.status] }])

        }
        if let c = match("POST", "api/device/sync-requests/:/ack") {
            let id = c[0]
            guard let index = syncRequests.firstIndex(where: { $0.id == id }) else { return error(url, 404, "request_not_found") }
            let wasPending = syncRequests[index].status == "pending"
            if wasPending { syncRequests[index].status = "acknowledged" }
            return respond(url, 200, ["request": ["id": id, "status": syncRequests[index].status], "acknowledged": wasPending])

        }
        if match("POST", "api/sync/runs") != nil {
            let body = jsonBody(request)
            guard let runId = body["runId"] as? String, runId == runId.lowercased(), UUID(uuidString: runId) != nil,
                  let mode = body["mode"] as? String, body["formatVersion"] as? Int == 1, body["currency"] as? String == "USD",
                  body["exportedAt"] is String
            else { return error(url, 400, "invalid_request") }
            if let existing = runs[runId] {
                guard existing.deviceId == device.id, existing.mode == mode else { return error(url, 409, "run_id_conflict") }
                return respond(url, 200, ["run": runJSON(existing), "created": false])
            }
            let requestId = body["requestId"] as? String
            if let requestId, !syncRequests.contains(where: { $0.id == requestId }) { return error(url, 400, "unknown_request") }
            let run = Run(id: runId, deviceId: device.id, mode: mode, requestId: requestId, status: "open")
            runs[runId] = run
            return respond(url, 201, ["run": runJSON(run), "created": true])

        }
        if let c = match("GET", "api/sync/runs/:") {
            let runId = c[0]
            guard let run = runs[runId], run.deviceId == device.id else { return error(url, 404, "run_not_found") }
            return respond(url, 200, ["run": runJSON(run), "receivedSeqs": run.batches.keys.sorted()])

        }
        if let c = match("PUT", "api/sync/runs/:/batches/:") {
            let runId = c[0], seqText = c[1]
            guard var run = runs[runId], run.deviceId == device.id, let seq = Int(seqText) else { return error(url, 404, "run_not_found") }
            let body = request.httpBody ?? Data()
            let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            if let prior = run.batches[seq] {
                return prior == hash ? respond(url, 200, ["runId": runId, "seq": seq, "replayed": true]) : error(url, 409, "batch_conflict")
            }
            guard run.status == "open" else { return error(url, 409, "run_not_open") }
            guard let batch = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let bundles = batch["receipts"] as? [[String: Any]],
                  let rets = batch["returns"] as? [[String: Any]],
                  let adjs = batch["priceAdjustments"] as? [[String: Any]]
            else { return error(url, 400, "invalid_batch") }
            let rows = bundles.reduce(0) { $0 + 1 + (($1["items"] as? [Any])?.count ?? 0) } + rets.count + adjs.count
            guard rows <= 200, body.count <= 256 * 1024 else { return error(url, 413, "batch_too_large") }
            for b in bundles { let id = b["id"] as! String; receipts[id] = try! JSONSerialization.data(withJSONObject: b); tombstoned.remove(id) }
            for r in rets { let id = r["id"] as! String; returns[id] = try! JSONSerialization.data(withJSONObject: r); tombstoned.remove(id) }
            for a in adjs { let id = a["id"] as! String; adjustments[id] = try! JSONSerialization.data(withJSONObject: a); tombstoned.remove(id) }
            run.batches[seq] = hash
            run.rowsSent["receipts", default: 0] += bundles.count
            run.rowsSent["returns", default: 0] += rets.count
            run.rowsSent["priceAdjustments", default: 0] += adjs.count
            runs[runId] = run
            return respond(url, 200, ["runId": runId, "seq": seq, "replayed": false])

        }
        if let c = match("POST", "api/sync/runs/:/complete") {
            let runId = c[0]
            guard var run = runs[runId], run.deviceId == device.id else { return error(url, 404, "run_not_found") }
            if run.status == "completed" || run.status == "needs_review" { return respond(url, 200, ["run": runJSON(run)]) }
            guard run.status == "open" else { return error(url, 409, "run_not_open") }
            let body = jsonBody(request)
            let count = body["batchCount"] as? Int ?? -1
            let missing = (0..<max(count, 0)).filter { run.batches[$0] == nil }
            if !missing.isEmpty || run.batches.keys.contains(where: { $0 >= count }) {
                return error(url, 409, "missing_batches", extra: ["missingSeqs": missing])
            }
            if run.mode == "full" {
                guard let manifest = body["manifest"] as? [String: [String]] else { return error(url, 400, "manifest_required") }
                let r = manifest["receiptIds"] ?? [], t = manifest["returnIds"] ?? [], a = manifest["priceAdjustmentIds"] ?? []
                guard r.count == run.rowsSent["receipts"], t.count == run.rowsSent["returns"], a.count == run.rowsSent["priceAdjustments"] else {
                    return error(url, 409, "manifest_mismatch")
                }
                let removals = [
                    "receipts": Set(receipts.keys).subtracting(tombstoned).subtracting(r),
                    "returns": Set(returns.keys).subtracting(tombstoned).subtracting(t),
                    "priceAdjustments": Set(adjustments.keys).subtracting(tombstoned).subtracting(a),
                ]
                let live = ["receipts": receipts.count, "returns": returns.count, "priceAdjustments": adjustments.count]
                let tripped = removals.contains { kind, ids in
                    ids.count > 50 || (live[kind]! > 0 && Double(ids.count) / Double(live[kind]!) > 0.2)
                }
                if tripped {
                    run.status = "needs_review"
                    run.pendingRemovals = removals.mapValues(\.count)
                } else {
                    for ids in removals.values { tombstoned.formUnion(ids) }
                    run.status = "completed"
                }
            } else if body["manifest"] != nil {
                return error(url, 400, "manifest_not_allowed")
            } else {
                run.status = "completed"
            }
            if let requestId = run.requestId, let index = syncRequests.firstIndex(where: { $0.id == requestId }) {
                syncRequests[index].status = "fulfilled"
            }
            runs[runId] = run
            return respond(url, 200, ["run": runJSON(run)])

        }
        if let c = match("POST", "api/sync/runs/:/abort") {
            let runId = c[0]
            guard var run = runs[runId], run.deviceId == device.id else { return error(url, 404, "run_not_found") }
            if run.status == "open" { run.status = "aborted" }
            runs[runId] = run
            return respond(url, 200, ["run": runJSON(run)])
        }
        return error(url, 404, "not_found")
    }
}

// MARK: - Coordinator harness

final class SourceState {
    var snapshot: SourceSnapshot
    var status: AnalyticsSourceStatus

    init(snapshot: SourceSnapshot, status: AnalyticsSourceStatus) {
        self.snapshot = snapshot
        self.status = status
    }
}

struct Harness {
    let server: FakeAnalyticsServer
    let secrets: AnalyticsSecretStore
    let defaults: UserDefaults
    let stateDirectory: URL
    let source: SourceState
    let clock: TestClock
    var sync: AnalyticsCloudSync

    final class TestClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    static func make(
        server: FakeAnalyticsServer = FakeAnalyticsServer(),
        secrets: AnalyticsSecretStore = InMemoryAnalyticsSecretStore(),
        defaults: UserDefaults? = nil,
        stateDirectory: URL? = nil,
        snapshot: SourceSnapshot? = nil
    ) throws -> Harness {
        let clock = TestClock(server.now)
        let fresh = AnalyticsSourceStatus(
            lastWarehouseSync: clock.now.addingTimeInterval(-60),
            lastOnlineSync: clock.now.addingTimeInterval(-60),
            onlineBackfillComplete: true
        )
        let source = SourceState(snapshot: try snapshot ?? Fixtures.sourceSnapshot(), status: fresh)
        let defaults = defaults ?? UserDefaults(suiteName: "analytics-test-\(UUID().uuidString)")!
        let directory = stateDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("analytics-test-\(UUID().uuidString)")
        let sync = AnalyticsCloudSync(
            dependencies: AnalyticsCloudDependencies(
                secrets: secrets,
                defaults: defaults,
                transport: server,
                stateStore: AnalyticsUploadStateStore(directory: directory),
                snapshot: { source.snapshot },
                sourceStatus: { source.status },
                now: { clock.now },
                retryDelays: [0, 0, 0],
                sleep: { _ in }
            )
        )
        return Harness(server: server, secrets: secrets, defaults: defaults, stateDirectory: directory, source: source, clock: clock, sync: sync)
    }

    /// A new coordinator over the same stores, like an app relaunch.
    func relaunched() -> AnalyticsCloudSync {
        let source = self.source
        let clock = self.clock
        return AnalyticsCloudSync(
            dependencies: AnalyticsCloudDependencies(
                secrets: secrets,
                defaults: defaults,
                transport: server,
                stateStore: AnalyticsUploadStateStore(directory: stateDirectory),
                snapshot: { source.snapshot },
                sourceStatus: { source.status },
                now: { clock.now },
                retryDelays: [0, 0, 0],
                sleep: { _ in }
            )
        )
    }

    func connect() async throws {
        let code = server.issueCode()
        let error = await sync.connect(code: code, deviceName: "Test iPhone")
        if let error { throw HarnessError.connectFailed(error) }
    }

    enum HarnessError: Error { case connectFailed(String) }
}
