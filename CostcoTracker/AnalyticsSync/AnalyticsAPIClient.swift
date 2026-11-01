import Foundation

// MARK: - CostcoTracker Analytics device API
//
// Endpoints used (all JSON, same paths as the deployed Analytics backend):
//   POST /api/device/enroll                         {code, deviceName} → {deviceId, deviceToken, idKey}
//   GET  /api/device/config                         → {deviceId, idKey, formatVersion, limits}
//   GET  /api/device/sync-requests                  → {requests:[{id, requested_at, status}]}
//   POST /api/device/sync-requests/:id/ack          → {request, acknowledged}
//   POST /api/sync/runs                             start (idempotent per runId)
//   GET  /api/sync/runs/:runId                      → {run, receivedSeqs}
//   PUT  /api/sync/runs/:runId/batches/:seq         idempotent batch upload
//   POST /api/sync/runs/:runId/complete             {batchCount, manifest?}
//   POST /api/sync/runs/:runId/abort
//
// The device token is sent only as an Authorization header to the configured
// Analytics origin. Request/response bodies, tokens and keys are never logged.

protocol AnalyticsHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAnalyticsTransport: AnalyticsHTTPTransport {
    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

nonisolated enum AnalyticsAPIError: Error, Equatable {
    /// No response (offline, DNS, TLS, timeout).
    case network
    /// The server answered with an error envelope or an unexpected status.
    case server(status: Int, code: String, message: String, missingSeqs: [Int] = [], issuePaths: [String] = [])
    /// The response could not be understood.
    case invalidResponse

    var status: Int? {
        if case .server(let status, _, _, _, _) = self { return status }
        return nil
    }

    var code: String? {
        if case .server(_, let code, _, _, _) = self { return code }
        return nil
    }

    /// Safe to retry later with the same request (network trouble, overload, server hiccup).
    var isTransient: Bool {
        switch self {
        case .network: return true
        case .invalidResponse: return false
        case .server(let status, _, _, _, _): return status == 429 || status >= 500
        }
    }

    /// The device token is no longer accepted (revoked, or never valid).
    var isUnauthenticated: Bool { status == 401 && code != "invalid_code" }
}

nonisolated struct AnalyticsEnrollment: Decodable, Equatable, Sendable {
    var deviceId: String
    var deviceToken: String
    var idKey: String
}

nonisolated struct AnalyticsDeviceConfig: Decodable, Equatable, Sendable {
    var deviceId: String
    var idKey: String
    var formatVersion: Int
}

nonisolated struct AnalyticsSyncRequest: Decodable, Equatable, Sendable {
    var id: String
    var requestedAt: String
    var status: String

    private enum CodingKeys: String, CodingKey {
        case id, status
        case requestedAt = "requested_at"
    }
}

nonisolated struct AnalyticsRunInfo: Decodable, Equatable, Sendable {
    var id: String
    var status: String
    var mode: String
    var batchCount: Int?
    var markedMissing: Int?
    var pendingRemovals: PendingRemovals?

    struct PendingRemovals: Decodable, Equatable, Sendable {
        var receipts: Int
        var returns: Int
        var priceAdjustments: Int
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, mode, pendingRemovals
        case batchCount = "batch_count"
        case markedMissing = "marked_missing"
    }
}

struct AnalyticsAPIClient {
    var baseURL: URL
    var transport: AnalyticsHTTPTransport
    /// Bearer token supplier; read from the Keychain at call time.
    var deviceToken: () -> String?

    // MARK: Device

    func enroll(code: String, deviceName: String) async throws -> AnalyticsEnrollment {
        try await request("POST", "/api/device/enroll", body: ["code": code, "deviceName": deviceName], authenticated: false)
    }

    func config() async throws -> AnalyticsDeviceConfig {
        try await request("GET", "/api/device/config")
    }

    func syncRequests() async throws -> [AnalyticsSyncRequest] {
        struct Response: Decodable { var requests: [AnalyticsSyncRequest] }
        let response: Response = try await request("GET", "/api/device/sync-requests")
        return response.requests
    }

    func acknowledge(requestId: String) async throws {
        struct Response: Decodable { var acknowledged: Bool }
        let _: Response = try await request("POST", "/api/device/sync-requests/\(pathComponent(requestId))/ack", body: EmptyBody())
    }

    // MARK: Sync runs

    func startRun(runId: String, mode: AnalyticsSyncMode, exportedAt: String, requestId: String?) async throws -> AnalyticsRunInfo {
        struct Body: Encodable {
            var runId: String
            var mode: String
            var formatVersion: Int
            var exportedAt: String
            var currency: String
            var requestId: String?

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(runId, forKey: .runId)
                try c.encode(mode, forKey: .mode)
                try c.encode(formatVersion, forKey: .formatVersion)
                try c.encode(exportedAt, forKey: .exportedAt)
                try c.encode(currency, forKey: .currency)
                try c.encode(requestId, forKey: .requestId)
            }

            private enum CodingKeys: String, CodingKey { case runId, mode, formatVersion, exportedAt, currency, requestId }
        }
        struct Response: Decodable { var run: AnalyticsRunInfo }
        let response: Response = try await request(
            "POST",
            "/api/sync/runs",
            body: Body(
                runId: runId,
                mode: mode.rawValue,
                formatVersion: AnalyticsFormat.version,
                exportedAt: exportedAt,
                currency: AnalyticsFormat.currency,
                requestId: requestId
            )
        )
        return response.run
    }

    func runStatus(runId: String) async throws -> (run: AnalyticsRunInfo, receivedSeqs: [Int]) {
        struct Response: Decodable { var run: AnalyticsRunInfo; var receivedSeqs: [Int] }
        let response: Response = try await request("GET", "/api/sync/runs/\(pathComponent(runId))")
        return (response.run, response.receivedSeqs)
    }

    func putBatch(runId: String, seq: Int, body: Data) async throws {
        struct Response: Decodable { var replayed: Bool }
        let _: Response = try await request("PUT", "/api/sync/runs/\(pathComponent(runId))/batches/\(seq)", rawBody: body)
    }

    func completeRun(runId: String, batchCount: Int, manifest: AnalyticsManifest?) async throws -> AnalyticsRunInfo {
        struct Body: Encodable { var batchCount: Int; var manifest: AnalyticsManifest? }
        struct Response: Decodable { var run: AnalyticsRunInfo }
        let response: Response = try await request(
            "POST",
            "/api/sync/runs/\(pathComponent(runId))/complete",
            body: Body(batchCount: batchCount, manifest: manifest)
        )
        return response.run
    }

    func abortRun(runId: String) async throws {
        struct Response: Decodable { var run: AnalyticsRunInfo }
        let _: Response = try await request("POST", "/api/sync/runs/\(pathComponent(runId))/abort", body: EmptyBody())
    }

    // MARK: Plumbing

    private struct EmptyBody: Encodable {}

    private func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? value
    }

    private func request<Response: Decodable, Body: Encodable>(
        _ method: String,
        _ path: String,
        body: Body,
        authenticated: Bool = true
    ) async throws -> Response {
        try await request(method, path, rawBody: try JSONEncoder().encode(body), authenticated: authenticated)
    }

    private func request<Response: Decodable>(
        _ method: String,
        _ path: String,
        rawBody: Data? = nil,
        authenticated: Bool = true
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw AnalyticsAPIError.invalidResponse }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpShouldHandleCookies = false
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        if let rawBody {
            urlRequest.httpBody = rawBody
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token = deviceToken(), !token.isEmpty else {
                throw AnalyticsAPIError.server(status: 401, code: "unauthenticated", message: "This iPhone is not connected.")
            }
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch let error as AnalyticsAPIError {
            throw error
        } catch {
            throw AnalyticsAPIError.network
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Self.decodeError(status: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AnalyticsAPIError.invalidResponse
        }
    }

    static func decodeError(status: Int, data: Data) -> AnalyticsAPIError {
        struct Envelope: Decodable {
            struct Body: Decodable {
                var code: String
                var message: String
                var missingSeqs: [Int]?
                var issues: [Issue]?
            }
            struct Issue: Decodable { var path: String }
            var error: Body
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return .server(
                status: status,
                code: envelope.error.code,
                message: envelope.error.message,
                missingSeqs: envelope.error.missingSeqs ?? [],
                issuePaths: (envelope.error.issues ?? []).map(\.path)
            )
        }
        return .server(status: status, code: "http_\(status)", message: "The Analytics server returned HTTP \(status).")
    }
}
