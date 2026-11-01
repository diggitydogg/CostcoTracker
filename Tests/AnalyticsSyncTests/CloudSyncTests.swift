import Foundation
import Testing
@testable import AnalyticsSync

@Suite("Enrollment and credentials")
struct EnrollmentTests {

    @Test("Connects with a website code, stores secrets only in the secret store, and verifies config")
    func connect() async throws {
        let h = try Harness.make()
        try await h.connect()
        guard case .connected(let deviceId, let name) = h.sync.connection else { Issue.record("not connected"); return }
        #expect(deviceId == "dev_test1")
        #expect(name == "Test iPhone")
        #expect(h.secrets.read(AnalyticsSecretAccount.deviceToken)?.hasPrefix("token_1_") == true)
        #expect(h.secrets.read(AnalyticsSecretAccount.idKey) == Fixtures.idKey)
        #expect(h.server.requests(method: "GET", pathPrefix: "/api/device/config").count == 1)
        // No secret values in UserDefaults.
        let stored = h.defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.joined()
        #expect(!stored.contains("token_1_"))
        #expect(!stored.contains(Fixtures.idKey))
        // Enrollment is unauthenticated; the token is never put in a URL.
        #expect(h.server.requests(method: "POST", pathPrefix: "/api/device/enroll").first?.authorization == nil)
        #expect(!h.server.log.contains { $0.url.absoluteString.contains("token_") })
    }

    @Test("Connection survives an app relaunch")
    func persistsAcrossRelaunch() async throws {
        let h = try Harness.make()
        try await h.connect()
        let relaunched = h.relaunched()
        guard case .connected(let deviceId, _) = relaunched.connection else { Issue.record("lost connection"); return }
        #expect(deviceId == "dev_test1")
    }

    @Test("Rejects an expired code with a clear message")
    func expiredCode() async throws {
        let h = try Harness.make()
        let code = h.server.issueCode(validFor: -1)
        let message = await h.sync.connect(code: code, deviceName: "Phone")
        #expect(message?.contains("expired") == true)
        #expect(h.sync.connection == .disconnected)
        #expect(h.secrets.read(AnalyticsSecretAccount.deviceToken) == nil)
    }

    @Test("Rejects a reused code")
    func reusedCode() async throws {
        let h = try Harness.make()
        let code = h.server.issueCode()
        #expect(await h.sync.connect(code: code, deviceName: "A") == nil)
        let other = try Harness.make(server: h.server)
        let message = await other.sync.connect(code: code, deviceName: "B")
        #expect(message?.contains("already used") == true)
        #expect(other.sync.connection == .disconnected)
    }

    @Test("Reports a network failure without storing anything")
    func networkFailure() async throws {
        let h = try Harness.make()
        h.server.fail(.network) { _, path in path == "/api/device/enroll" }
        let message = await h.sync.connect(code: h.server.issueCode(), deviceName: "Phone")
        #expect(message?.contains("Couldn't reach") == true)
        #expect(h.secrets.read(AnalyticsSecretAccount.deviceToken) == nil)
    }

    @Test("Reports throttling and server errors")
    func serverRejections() async throws {
        let h = try Harness.make()
        h.server.fail(.status(429, code: "too_many_attempts")) { _, path in path == "/api/device/enroll" }
        #expect(await h.sync.connect(code: h.server.issueCode(), deviceName: "P")?.contains("Too many attempts") == true)
        h.server.fail(.status(503, code: "temporarily_unavailable")) { _, path in path == "/api/device/enroll" }
        #expect(await h.sync.connect(code: h.server.issueCode("ZZZZZ-11111"), deviceName: "P")?.contains("unavailable") == true)
        #expect(await h.sync.connect(code: "   ", deviceName: "P")?.contains("Enter the connection code") == true)
    }

    @Test("Keeps the connection if verification fails only because of the network")
    func verificationOffline() async throws {
        let h = try Harness.make()
        h.server.fail(.network) { _, path in path == "/api/device/config" }
        #expect(await h.sync.connect(code: h.server.issueCode(), deviceName: "P") == nil)
        guard case .connected = h.sync.connection else { Issue.record("should stay connected"); return }
        #expect(h.sync.lastError?.contains("couldn't be verified") == true)
    }

    @Test("Disconnect forgets secrets, metadata and upload state")
    func disconnect() async throws {
        let h = try Harness.make()
        try await h.connect()
        await h.sync.sync(trigger: .manual)
        h.sync.disconnect()
        #expect(h.sync.connection == .disconnected)
        #expect(h.secrets.read(AnalyticsSecretAccount.deviceToken) == nil)
        #expect(h.secrets.read(AnalyticsSecretAccount.idKey) == nil)
        #expect(h.defaults.string(forKey: AnalyticsCloudDefaultsKey.deviceId) == nil)
        #expect(h.sync.lastUploadAt == nil)
    }

    @Test("Server URL can only be changed while disconnected and must be https (or local http)")
    func serverURL() async throws {
        let h = try Harness.make()
        #expect(h.sync.serverURL.absoluteString == "https://costcotracker-analytics.pages.dev")
        #expect(!h.sync.setServerURL("http://example.com"))
        #expect(!h.sync.setServerURL("https://user:pw@example.com"))
        #expect(h.sync.setServerURL("http://localhost:8788"))
        #expect(h.sync.serverURL.absoluteString == "http://localhost:8788")
        #expect(h.sync.setServerURL(""))
        try await h.connect()
        #expect(!h.sync.setServerURL("https://other.example"))
    }
}

@Suite("Revocation")
struct RevocationTests {

    @Test("A revoked token clears credentials and asks for a new code")
    func revoked() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.server.revokeAllDevices()
        await h.sync.sync(trigger: .manual)
        #expect(h.sync.connection == .revoked)
        #expect(h.secrets.read(AnalyticsSecretAccount.deviceToken) == nil)
        #expect(h.sync.lastError?.contains("disconnected") == true)
        // Reconnecting with a new code works and clears the revoked state.
        try await h.connect()
        guard case .connected = h.sync.connection else { Issue.record("not reconnected"); return }
    }

    @Test("Request polling also detects revocation")
    func revokedWhilePolling() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.server.revokeAllDevices()
        await h.sync.appDidBecomeActive()
        #expect(h.sync.connection == .revoked)
    }
}

@Suite("Uploads")
struct UploadTests {

    @Test("First sync uploads everything; IDs on the server are the deterministic export IDs")
    func firstSync() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.sync.setLastFullSyncForTesting(nil)
        await h.sync.sync(trigger: .manual)
        #expect(h.sync.lastError == nil)
        #expect(h.server.receipts.count == 5)
        #expect(h.server.returns.count == 4)
        #expect(h.server.adjustments.count == 3)
        let ids = try AnalyticsIDDeriver(idKey: Fixtures.idKey)
        #expect(h.server.receipts[ids.receiptID(barcode: "SYNTH-ORD-1001")] != nil)
        #expect(h.sync.lastUploadAt != nil)
    }

    @Test("Never uploads raw barcodes, order keys or credential-like fields")
    func noLeakage() async throws {
        let h = try Harness.make()
        try await h.connect()
        await h.sync.sync(trigger: .manual, forceMode: .full)
        let bodies = String(decoding: h.server.allUploadedBodies, as: UTF8.self)
        #expect(!bodies.isEmpty)
        for key in try Fixtures.rawSourceKeys() { #expect(!bodies.contains(key)) }
        #expect(!bodies.contains("WHSE_"))
        for name in ["cookie", "password", "session", "barcode", "\"token", "authorization"] {
            #expect(!bodies.lowercased().contains(name), "body mentions \(name)")
        }
        // The device token only ever travels in the Authorization header.
        #expect(!bodies.contains("token_1_"))
    }

    @Test("Incremental sync sends nothing when nothing changed, then only the changed receipt")
    func incremental() async throws {
        let h = try Harness.make()
        try await h.connect()
        await h.sync.sync(trigger: .manual, forceMode: .full)
        let runsBefore = h.server.runs.count

        await h.sync.sync(trigger: .manual, forceMode: .incremental)
        #expect(h.server.runs.count == runsBefore) // no run at all
        #expect(h.sync.lastUploadSummary?.hasPrefix("Already up to date") == true)

        h.source.snapshot.items[0].unitPrice = 20.99
        await h.sync.sync(trigger: .manual, forceMode: .incremental)
        #expect(h.server.runs.count == runsBefore + 1)
        let lastPut = try #require(h.server.requests(method: "PUT", pathPrefix: "/api/sync/runs").last?.body)
        let batch = try JSONSerialization.jsonObject(with: lastPut) as! [String: [Any]]
        #expect(batch["receipts"]?.count == 1)
        #expect(h.sync.lastUploadSummary?.contains("Uploaded 3 records") == true) // 1 receipt + 2 items
    }

    @Test("Full sync sends a manifest; a small removal is reconciled by the server")
    func fullSyncReconciles() async throws {
        var snapshot = try Fixtures.sourceSnapshot()
        for i in 0..<20 {
            snapshot.receipts.append(SourceReceiptRow(barcode: "99990000000000001\(100 + i)", date: "2026-03-01", warehouse: "SYNTHETIC"))
        }
        let h = try Harness.make(snapshot: snapshot)
        try await h.connect()
        await h.sync.sync(trigger: .manual, forceMode: .full)
        h.source.snapshot.receipts.removeLast()
        await h.sync.sync(trigger: .manual, forceMode: .full)
        #expect(h.server.tombstoned.count == 1)
        let complete = try #require(h.server.requests(method: "POST", pathPrefix: "/api/sync/runs").last { $0.path.hasSuffix("/complete") })
        let body = try JSONSerialization.jsonObject(with: complete.body!) as! [String: Any]
        #expect((body["manifest"] as? [String: [String]])?["receiptIds"]?.count == 24)
        #expect(h.sync.lastFullSyncAt != nil)
    }

    @Test("A wiped local database never deletes cloud history: the server holds removals for review")
    func massRemovalHeldForReview() async throws {
        let h = try Harness.make()
        try await h.connect()
        await h.sync.sync(trigger: .manual, forceMode: .full)
        h.source.snapshot = SourceSnapshot(receipts: [h.source.snapshot.receipts[0]])
        await h.sync.sync(trigger: .manual, forceMode: .full)
        #expect(h.server.tombstoned.isEmpty)
        #expect(h.sync.lastRunStatus == "needs_review")
        #expect(h.sync.lastUploadSummary?.contains("waiting for your review") == true)
    }

    @Test("Mode choice: weekly full only after a complete Costco refresh; partial refresh stays incremental")
    func modeDecision() async throws {
        let h = try Harness.make()
        try await h.connect()
        #expect(h.sync.decideMode(for: .afterCostcoRefresh(partial: false)) == .full) // never done before
        #expect(h.sync.decideMode(for: .afterCostcoRefresh(partial: true)) == .incremental)
        #expect(h.sync.decideMode(for: .background) == .incremental)

        h.source.status.onlineBackfillComplete = false
        #expect(h.sync.decideMode(for: .manual) == .incremental) // partial source database

        h.source.status.onlineBackfillComplete = true
        h.sync.setLastFullSyncForTesting(h.clock.now.addingTimeInterval(-60))
        #expect(h.sync.decideMode(for: .manual) == .incremental) // not due yet
        h.sync.setLastFullSyncForTesting(h.clock.now.addingTimeInterval(-8 * 24 * 3600))
        #expect(h.sync.decideMode(for: .afterCostcoRefresh(partial: false)) == .full)
    }

    @Test("Partial Costco refresh triggers only an incremental upload, even when a full sync is due")
    func partialSourceSync() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.sync.costcoRefreshWillBegin()
        h.source.status.lastWarehouseSync = h.clock.now.addingTimeInterval(1) // warehouse succeeded, online failed
        await h.sync.costcoRefreshDidEnd()
        let start = try #require(h.server.requests(method: "POST", pathPrefix: "/api/sync/runs").first { $0.path == "/api/sync/runs" })
        let body = try JSONSerialization.jsonObject(with: start.body!) as! [String: Any]
        #expect(body["mode"] as? String == "incremental")
        #expect(h.server.requests(method: "POST", pathPrefix: "/api/sync/runs").allSatisfy { !$0.path.hasSuffix("/complete") || !String(decoding: $0.body ?? Data(), as: UTF8.self).contains("manifest") })
    }

    @Test("No upload when the Costco sheet closes without a successful refresh")
    func noRefreshNoUpload() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.sync.costcoRefreshWillBegin()
        await h.sync.costcoRefreshDidEnd()
        #expect(h.server.runs.isEmpty)
    }
}

@Suite("Retry and resume")
struct RetryResumeTests {

    @Test("Transient failures are retried transparently")
    func retry() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.server.fail(.network, times: 2) { method, path in method == "PUT" && path.hasSuffix("/batches/0") }
        h.server.fail(.status(503, code: "temporarily_unavailable")) { method, path in method == "POST" && path.hasSuffix("/complete") }
        await h.sync.sync(trigger: .manual, forceMode: .full)
        #expect(h.sync.lastError == nil)
        #expect(h.server.runs.values.first?.status == "completed")
        #expect(h.server.receipts.count == 5)
    }

    @Test("An interrupted upload resumes from the server's received batches without duplicates")
    func resume() async throws {
        var snapshot = try Fixtures.sourceSnapshot()
        for r in 0..<20 {
            let barcode = "9999000000000000\(2000 + r)"
            snapshot.receipts.append(SourceReceiptRow(barcode: barcode, date: "2026-01-01", warehouse: "SYNTHETIC"))
            for i in 0..<15 {
                snapshot.items.append(SourceItemRow(rowID: Int64(10_000 + r * 100 + i), receiptBarcode: barcode, itemNumber: "\(i)", description: "S", unitPrice: 1, quantity: 1))
            }
        }
        let h = try Harness.make(snapshot: snapshot)
        try await h.connect()
        h.server.fail(.network, times: 10) { method, path in method == "PUT" && path.hasSuffix("/batches/1") }
        await h.sync.sync(trigger: .manual, forceMode: .full)
        #expect(h.sync.hasInterruptedUpload)
        #expect(h.sync.lastError?.contains("Upload paused") == true)
        let runId = try #require(h.server.runs.keys.first)
        #expect(h.server.runs[runId]?.status == "open")

        h.server.faults.removeAll()
        // App relaunch: resumes the same run.
        let relaunched = h.relaunched()
        await relaunched.appDidLaunch()
        #expect(!relaunched.hasInterruptedUpload)
        #expect(h.server.runs.count == 1)
        #expect(h.server.runs[runId]?.status == "completed")
        let batch0Puts = h.server.requests(method: "PUT", pathPrefix: "/api/sync/runs/\(runId)/batches/0")
        #expect(batch0Puts.count == 1) // already received; not resent
        #expect(h.server.receipts.count == 25)
        #expect(relaunched.lastError == nil)
    }

    @Test("A resent batch is byte-identical (server replays it)")
    func idempotentResend() async throws {
        let h = try Harness.make()
        try await h.connect()
        // Lose the response of batch 0 once: the server stored it, the client resends it.
        h.server.fail(.status(502, code: "bad_gateway")) { method, path in method == "POST" && path.hasSuffix("/complete") }
        await h.sync.sync(trigger: .manual, forceMode: .full)
        let puts = h.server.requests(method: "PUT", pathPrefix: "/api/sync/runs")
        #expect(Set(puts.compactMap(\.body)).count == puts.count) // no conflicting duplicates
        #expect(h.server.runs.values.allSatisfy { $0.status == "completed" })
    }

    @Test("A rejected batch aborts the run and is not retried")
    func rejected() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.server.fail(.status(400, code: "invalid_batch"), times: 5) { method, _ in method == "PUT" }
        await h.sync.sync(trigger: .manual, forceMode: .full)
        #expect(h.server.requests(method: "PUT", pathPrefix: "/api/sync/runs").count == 1)
        #expect(h.server.runs.values.first?.status == "aborted")
        #expect(!h.sync.hasInterruptedUpload)
        #expect(h.sync.lastError?.contains("invalid_batch") == true)
    }

    @Test("A run that expired on the server is dropped and the next sync starts fresh")
    func expiredRun() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.server.fail(.network, times: 10) { method, _ in method == "PUT" }
        await h.sync.sync(trigger: .manual, forceMode: .full)
        let oldRun = try #require(h.server.runs.keys.first)
        h.server.runs[oldRun]?.status = "abandoned"
        h.server.faults.removeAll()
        await h.sync.sync(trigger: .manual, forceMode: .full)
        #expect(h.server.runs.count == 2)
        #expect(h.server.runs.values.contains { $0.status == "completed" })
    }
}

@Suite("Website sync requests")
struct SyncRequestTests {

    @Test("A request with fresh local data is acknowledged and fulfilled immediately")
    func freshData() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.server.addSyncRequest("req_fresh")
        await h.sync.appDidBecomeActive()
        #expect(h.server.syncRequests.first?.status == "fulfilled")
        let run = try #require(h.server.runs.values.first)
        #expect(run.requestId == "req_fresh")
        #expect(!h.sync.requestNeedsCostcoRefresh)
    }

    @Test("A request with stale data waits for a Costco refresh, then is fulfilled by it")
    func staleData() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.source.status.lastWarehouseSync = h.clock.now.addingTimeInterval(-3 * 24 * 3600)
        h.source.status.lastOnlineSync = h.clock.now.addingTimeInterval(-3 * 24 * 3600)
        h.server.addSyncRequest("req_stale")
        await h.sync.appDidLaunch()
        #expect(h.server.syncRequests.first?.status == "acknowledged")
        #expect(h.sync.requestNeedsCostcoRefresh)
        #expect(h.server.runs.isEmpty)

        h.sync.costcoRefreshWillBegin()
        h.source.status.lastWarehouseSync = h.clock.now
        h.source.status.lastOnlineSync = h.clock.now
        await h.sync.costcoRefreshDidEnd()
        #expect(h.server.syncRequests.first?.status == "fulfilled")
        #expect(h.server.runs.values.contains { $0.requestId == "req_stale" })
        #expect(!h.sync.requestNeedsCostcoRefresh)
    }

    @Test("A manual upload with stale data does not claim to fulfil the request")
    func manualDoesNotFulfil() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.source.status.lastWarehouseSync = h.clock.now.addingTimeInterval(-3 * 24 * 3600)
        h.server.addSyncRequest("req_manual")
        await h.sync.appDidLaunch()
        await h.sync.sync(trigger: .manual)
        #expect(h.server.runs.values.allSatisfy { $0.requestId == nil })
        #expect(h.server.syncRequests.first?.status == "acknowledged")
    }

    @Test("Polling failures are silent and harmless")
    func pollingOffline() async throws {
        let h = try Harness.make()
        try await h.connect()
        h.server.fail(.network) { _, path in path == "/api/device/sync-requests" }
        await h.sync.appDidBecomeActive()
        guard case .connected = h.sync.connection else { Issue.record("should stay connected"); return }
    }
}

@Suite("Backup and restore identity")
struct BackupRestoreIdentityTests {

    @Test("CostcoTracker backups never include cloud connection keys")
    func notInBackupAllowlist() throws {
        let source = try String(contentsOf: Fixtures.repoRoot.appendingPathComponent("CostcoTracker/BackupManager.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "backedUpDefaultsKeys = ["))
        let end = try #require(source.range(of: "]", range: start.upperBound..<source.endIndex))
        let allowlist = String(source[start.upperBound..<end.lowerBound])
        #expect(allowlist.contains("costco_saved_returns")) // sanity: found the right list
        for key in AnalyticsCloudDefaultsKey.all { #expect(!allowlist.contains(key)) }
        #expect(!allowlist.lowercased().contains("analytics"))
    }

    @Test("A replacement iPhone re-enrolls with a new token, gets the same idKey, and creates no duplicates")
    func replacementPhone() async throws {
        let server = FakeAnalyticsServer()
        let phoneA = try Harness.make(server: server)
        try await phoneA.connect()
        await phoneA.sync.sync(trigger: .manual, forceMode: .full)
        let receiptsAfterA = Set(server.receipts.keys)
        let tokenA = phoneA.secrets.read(AnalyticsSecretAccount.deviceToken)

        // Restore onto a new phone: same database contents, empty Keychain, only
        // backed-up (non-analytics) defaults, no upload-state files.
        let phoneB = try Harness.make(server: server, snapshot: phoneA.source.snapshot)
        #expect(phoneB.sync.connection == .disconnected)
        try await phoneB.connect()
        #expect(phoneB.secrets.read(AnalyticsSecretAccount.deviceToken) != tokenA)
        #expect(phoneB.secrets.read(AnalyticsSecretAccount.idKey) == phoneA.secrets.read(AnalyticsSecretAccount.idKey))
        await phoneB.sync.sync(trigger: .manual, forceMode: .full)
        #expect(Set(server.receipts.keys) == receiptsAfterA)
        #expect(server.tombstoned.isEmpty)
    }

    @Test("Restoring a backup on the same phone keeps the connection but resets upload state")
    func restoreOnSamePhone() async throws {
        let h = try Harness.make()
        try await h.connect()
        await h.sync.sync(trigger: .manual, forceMode: .full)
        await h.sync.localDataWasRestored()
        guard case .connected = h.sync.connection else { Issue.record("connection lost"); return }
        // With the upload cache cleared, the next incremental re-sends everything (server dedupes by ID).
        await h.sync.sync(trigger: .manual, forceMode: .incremental)
        #expect(h.server.runs.count == 2)
        #expect(h.server.receipts.count == 5)
    }

    @Test("Metadata without Keychain secrets is treated as disconnected")
    func metadataWithoutSecrets() async throws {
        let h = try Harness.make()
        h.defaults.set("dev_old", forKey: AnalyticsCloudDefaultsKey.deviceId)
        let relaunched = h.relaunched()
        #expect(relaunched.connection == .disconnected)
        #expect(h.defaults.string(forKey: AnalyticsCloudDefaultsKey.deviceId) == nil)
    }
}
