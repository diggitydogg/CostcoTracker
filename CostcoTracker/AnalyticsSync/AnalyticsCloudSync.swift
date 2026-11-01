import Combine
import CryptoKit
import Foundation
import os

// MARK: - CostcoTracker Analytics cloud sync coordinator
//
// Owns the connection (enroll / disconnect), decides when and how to upload,
// polls website sync requests, and exposes high-level status to the UI.
// It never runs or modifies the Costco sync itself: it only reads the local
// database after the existing sync has finished.
//
// When uploads happen
// - after the Costco sync sheet closes, if a warehouse or online refresh
//   succeeded (the existing success timestamps advanced)
// - when the user taps "Sync to Analytics"
// - when a website request is picked up and the local Costco data is fresh
// - an interrupted upload resumes on launch / foreground / background refresh
//
// Modes
// - incremental: only receipts/transactions whose content changed since the
//   last successful upload (the server also skips unchanged rows)
// - full: everything plus a manifest of all IDs, so the cloud can mark records
//   that disappeared (large removals are held for review on the website).
//   Runs at most weekly, and only after a fully successful Costco refresh with
//   online history backfilled — never after a partial refresh.

/// What the app knows about its own Costco sync, read from existing state.
nonisolated struct AnalyticsSourceStatus: Equatable, Sendable {
    var lastWarehouseSync: Date?
    var lastOnlineSync: Date?
    var onlineBackfillComplete: Bool

    /// The older of the two source timestamps (the app's "last synced" rule).
    var combinedLastSync: Date? {
        guard let warehouse = lastWarehouseSync, let online = lastOnlineSync else { return nil }
        return min(warehouse, online)
    }
}

nonisolated enum AnalyticsSyncTrigger: Equatable, Sendable {
    /// The Costco sync sheet closed; `partial` if only one source refreshed.
    case afterCostcoRefresh(partial: Bool)
    case manual
    /// A website request while local Costco data is already fresh.
    case websiteRequest
    case background
}

nonisolated enum AnalyticsConnectionState: Equatable, Sendable {
    case disconnected
    case connected(deviceId: String, deviceName: String?)
    /// The website disconnected this iPhone; a new code is needed.
    case revoked
}

struct AnalyticsCloudDependencies {
    var secrets: AnalyticsSecretStore
    var defaults: UserDefaults
    var transport: AnalyticsHTTPTransport
    var stateStore: AnalyticsUploadStateStore
    var snapshot: () throws -> SourceSnapshot
    var sourceStatus: () -> AnalyticsSourceStatus
    var now: () -> Date = { Date() }
    var retryDelays: [Double] = [1, 3, 8]
    var sleep: (Double) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

final class AnalyticsCloudSync: ObservableObject {

    static let fullSyncInterval: TimeInterval = 7 * 24 * 60 * 60
    /// A website request is fulfilled automatically only if Costco data was
    /// refreshed this recently; otherwise the app asks the user to refresh.
    static let requestFreshnessWindow: TimeInterval = 6 * 60 * 60

    @Published private(set) var connection: AnalyticsConnectionState = .disconnected
    @Published private(set) var isBusy = false
    @Published private(set) var activity: String?
    @Published private(set) var progress: AnalyticsUploadProgress?
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastUploadSummary: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastFullSyncAt: Date?
    /// A website request is waiting for a Costco refresh on this iPhone.
    @Published private(set) var requestNeedsCostcoRefresh = false

    private let deps: AnalyticsCloudDependencies
    private let log = Logger(subsystem: "com.danmcgoldrick.CostcoTracker", category: "AnalyticsCloudSync")
    private var sourceStatusAtSheetOpen: AnalyticsSourceStatus?

    init(dependencies: AnalyticsCloudDependencies) {
        deps = dependencies
        reloadState()
    }

    // MARK: Derived configuration

    var serverURL: URL {
        deps.defaults.string(forKey: AnalyticsCloudDefaultsKey.serverURL)
            .flatMap(AnalyticsCloudDefaults.validatedServerURL) ?? AnalyticsCloudDefaults.productionURL
    }

    var lastRunId: String? { deps.defaults.string(forKey: AnalyticsCloudDefaultsKey.lastRunId) }
    var lastRunStatus: String? { deps.defaults.string(forKey: AnalyticsCloudDefaultsKey.lastRunStatus) }
    var hasInterruptedUpload: Bool { deps.stateStore.loadPlan() != nil }
    var pendingRequestId: String? { deps.defaults.string(forKey: AnalyticsCloudDefaultsKey.pendingRequestId) }

    /// Debug/developer override. Only allowed while disconnected so a token is
    /// never sent to a different server than the one that issued it.
    @discardableResult
    func setServerURL(_ text: String) -> Bool {
        guard case .disconnected = connection else { return false }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            deps.defaults.removeObject(forKey: AnalyticsCloudDefaultsKey.serverURL)
            objectWillChange.send()
            return true
        }
        guard let url = AnalyticsCloudDefaults.validatedServerURL(text) else { return false }
        deps.defaults.set(url.absoluteString, forKey: AnalyticsCloudDefaultsKey.serverURL)
        objectWillChange.send()
        return true
    }

    private func client() -> AnalyticsAPIClient {
        let secrets = deps.secrets
        return AnalyticsAPIClient(
            baseURL: serverURL,
            transport: deps.transport,
            deviceToken: { secrets.read(AnalyticsSecretAccount.deviceToken) }
        )
    }

    private func uploader() -> AnalyticsUploader {
        AnalyticsUploader(client: client(), store: deps.stateStore, retryDelays: deps.retryDelays, sleep: deps.sleep)
    }

    private func reloadState() {
        let d = deps.defaults
        let token = deps.secrets.read(AnalyticsSecretAccount.deviceToken)
        let idKey = deps.secrets.read(AnalyticsSecretAccount.idKey)
        let deviceId = d.string(forKey: AnalyticsCloudDefaultsKey.deviceId)

        if let token, !token.isEmpty, let idKey, !idKey.isEmpty, let deviceId {
            connection = .connected(deviceId: deviceId, deviceName: d.string(forKey: AnalyticsCloudDefaultsKey.deviceName))
        } else {
            if deviceId != nil || token != nil || idKey != nil {
                // Metadata without secrets (e.g. Keychain unavailable after a
                // device migration): not usable — require reconnecting.
                clearConnection(keepRevokedFlag: d.bool(forKey: AnalyticsCloudDefaultsKey.revoked))
            }
            connection = d.bool(forKey: AnalyticsCloudDefaultsKey.revoked) ? .revoked : .disconnected
        }
        lastUploadAt = date(AnalyticsCloudDefaultsKey.lastUploadAt)
        lastUploadSummary = d.string(forKey: AnalyticsCloudDefaultsKey.lastUploadSummary)
        lastError = d.string(forKey: AnalyticsCloudDefaultsKey.lastError)
        lastFullSyncAt = date(AnalyticsCloudDefaultsKey.lastFullSyncAt)
        requestNeedsCostcoRefresh = pendingRequestId != nil
    }

    private func date(_ key: String) -> Date? {
        let value = deps.defaults.double(forKey: key)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    private func setDate(_ date: Date?, _ key: String) {
        if let date {
            deps.defaults.set(date.timeIntervalSince1970, forKey: key)
        } else {
            deps.defaults.removeObject(forKey: key)
        }
    }

    private func recordError(_ message: String?) {
        lastError = message
        deps.defaults.set(message, forKey: AnalyticsCloudDefaultsKey.lastError)
        setDate(message == nil ? nil : deps.now(), AnalyticsCloudDefaultsKey.lastErrorAt)
    }

    // MARK: Connect / disconnect

    /// Enrolls this iPhone with a one-time code from the website.
    /// Returns nil on success, otherwise a message for the user.
    func connect(code rawCode: String, deviceName rawName: String) async -> String? {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return "Enter the connection code shown on the website." }
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let deviceName = name.isEmpty ? "iPhone" : name

        isBusy = true
        activity = "Connecting…"
        defer {
            isBusy = false
            activity = nil
        }

        let enrollment: AnalyticsEnrollment
        do {
            enrollment = try await client().enroll(code: code, deviceName: deviceName)
        } catch let error as AnalyticsAPIError {
            return Self.enrollmentMessage(error)
        } catch {
            return "Couldn't connect. Try again."
        }

        guard (try? AnalyticsIDDeriver(idKey: enrollment.idKey)) != nil, !enrollment.deviceToken.isEmpty else {
            return "CostcoTracker Analytics returned an unexpected response. Nothing was saved."
        }

        // A different idKey means a different cloud: forget what was uploaded before.
        if deps.secrets.read(AnalyticsSecretAccount.idKey) != enrollment.idKey {
            deps.stateStore.clearAll()
            setDate(nil, AnalyticsCloudDefaultsKey.lastFullSyncAt)
        }
        do {
            try deps.secrets.write(enrollment.deviceToken, account: AnalyticsSecretAccount.deviceToken)
            try deps.secrets.write(enrollment.idKey, account: AnalyticsSecretAccount.idKey)
        } catch {
            try? deps.secrets.delete(AnalyticsSecretAccount.deviceToken)
            return "This iPhone couldn't store the connection securely (Keychain error). Nothing was saved."
        }
        deps.defaults.set(enrollment.deviceId, forKey: AnalyticsCloudDefaultsKey.deviceId)
        deps.defaults.set(deviceName, forKey: AnalyticsCloudDefaultsKey.deviceName)
        setDate(deps.now(), AnalyticsCloudDefaultsKey.connectedAt)
        deps.defaults.removeObject(forKey: AnalyticsCloudDefaultsKey.revoked)
        recordError(nil)
        reloadState()
        log.info("Analytics cloud connected")

        // Verify the connection end to end with the new token.
        do {
            let config = try await client().config()
            guard config.deviceId == enrollment.deviceId, config.idKey == enrollment.idKey,
                  config.formatVersion == AnalyticsFormat.version
            else {
                disconnect()
                return "CostcoTracker Analytics returned a configuration this version of the app can't use. Nothing was kept."
            }
        } catch let error as AnalyticsAPIError where error.isUnauthenticated {
            markRevoked()
            return "The website rejected this iPhone right after connecting. Create a new code and try again."
        } catch {
            // The code is already used; keep the connection and verify on the next sync.
            recordError("Connected, but the connection couldn't be verified yet. It will be checked on the next sync.")
        }
        return nil
    }

    static func enrollmentMessage(_ error: AnalyticsAPIError) -> String {
        switch error {
        case .network:
            return "Couldn't reach CostcoTracker Analytics. Check your connection and try again."
        case .invalidResponse:
            return "CostcoTracker Analytics returned an unexpected response."
        case .server(let status, let code, let message, _, _):
            switch (status, code) {
            case (401, "invalid_code"):
                return "That code is invalid, has expired, or was already used. Create a new code on the website and try again."
            case (429, _):
                return "Too many attempts. Wait 15 minutes, then try again."
            case (400, _):
                return message
            default:
                return status >= 500 ? "CostcoTracker Analytics is unavailable right now. Try again later." : message
            }
        }
    }

    /// Forgets the cloud connection on this iPhone. The website should also
    /// disconnect the device (a device cannot revoke its own token).
    func disconnect() {
        clearConnection(keepRevokedFlag: false)
        reloadState()
        log.info("Analytics cloud disconnected")
    }

    private func clearConnection(keepRevokedFlag: Bool) {
        try? deps.secrets.delete(AnalyticsSecretAccount.deviceToken)
        try? deps.secrets.delete(AnalyticsSecretAccount.idKey)
        deps.stateStore.clearAll()
        for key in AnalyticsCloudDefaultsKey.all where key != AnalyticsCloudDefaultsKey.serverURL {
            if keepRevokedFlag && key == AnalyticsCloudDefaultsKey.revoked { continue }
            deps.defaults.removeObject(forKey: key)
        }
    }

    private func markRevoked() {
        clearConnection(keepRevokedFlag: false)
        deps.defaults.set(true, forKey: AnalyticsCloudDefaultsKey.revoked)
        reloadState()
        recordError("This iPhone was disconnected from CostcoTracker Analytics. Create a new code on the website to reconnect.")
        log.notice("Analytics cloud token rejected; connection cleared")
    }

    // MARK: Lifecycle hooks

    func appDidLaunch() async { await foregroundCheck() }

    func appDidBecomeActive() async { await foregroundCheck() }

    private func foregroundCheck() async {
        guard case .connected = connection, !isBusy else { return }
        if hasInterruptedUpload {
            await resumeInterruptedUpload()
        }
        await checkSyncRequests(allowUpload: true)
    }

    /// Call when the Costco sync sheet is shown.
    func costcoRefreshWillBegin() {
        sourceStatusAtSheetOpen = deps.sourceStatus()
    }

    /// Call when the Costco sync sheet is dismissed (Done or swipe).
    func costcoRefreshDidEnd() async {
        let before = sourceStatusAtSheetOpen ?? AnalyticsSourceStatus(lastWarehouseSync: nil, lastOnlineSync: nil, onlineBackfillComplete: false)
        sourceStatusAtSheetOpen = nil
        let after = deps.sourceStatus()
        let warehouseRefreshed = Self.advanced(before.lastWarehouseSync, after.lastWarehouseSync)
        let onlineRefreshed = Self.advanced(before.lastOnlineSync, after.lastOnlineSync)

        guard case .connected = connection else { return }
        if warehouseRefreshed || onlineRefreshed {
            await sync(trigger: .afterCostcoRefresh(partial: !(warehouseRefreshed && onlineRefreshed)))
        }
        // A request noticed only now can be fulfilled if the data is fresh.
        await checkSyncRequests(allowUpload: true)
    }

    private static func advanced(_ before: Date?, _ after: Date?) -> Bool {
        guard let after else { return false }
        guard let before else { return true }
        return after > before
    }

    /// Background refresh: resume interrupted uploads and answer website
    /// requests when local data is fresh. Never runs a full sync.
    func backgroundRefresh() async {
        guard case .connected = connection, !isBusy else { return }
        if hasInterruptedUpload { await resumeInterruptedUpload() }
        await checkSyncRequests(allowUpload: true)
    }

    /// Call after a CostcoTracker backup was restored over the local database.
    /// The upload cache and any interrupted run describe data that no longer
    /// exists locally, so they are discarded; the next upload re-sends
    /// everything (unchanged rows cost nothing on the server). The cloud
    /// identity (Keychain) is untouched: backups never contain it.
    func localDataWasRestored() async {
        if case .connected = connection, let plan = deps.stateStore.loadPlan() {
            try? await client().abortRun(runId: plan.runId)
        }
        deps.stateStore.clearAll()
        log.info("Analytics upload cache cleared after restore")
    }

    // MARK: Website sync requests

    /// Picks up website "Refresh from Costco" requests: acknowledges them, and
    /// fulfils them right away only if Costco data on this iPhone is fresh.
    /// Otherwise the request waits for the user's next Costco refresh.
    func checkSyncRequests(allowUpload: Bool) async {
        guard case .connected = connection else { return }
        let requests: [AnalyticsSyncRequest]
        do {
            requests = try await client().syncRequests()
        } catch let error as AnalyticsAPIError where error.isUnauthenticated {
            markRevoked()
            return
        } catch {
            return // Polling is best-effort; try again next time.
        }

        guard let open = requests.first(where: { $0.status == "pending" || $0.status == "acknowledged" }) else {
            if pendingRequestId != nil {
                deps.defaults.removeObject(forKey: AnalyticsCloudDefaultsKey.pendingRequestId)
                requestNeedsCostcoRefresh = false
            }
            return
        }
        if open.status == "pending" {
            try? await client().acknowledge(requestId: open.id)
        }
        deps.defaults.set(open.id, forKey: AnalyticsCloudDefaultsKey.pendingRequestId)

        if allowUpload, isCostcoDataFresh() {
            await sync(trigger: .websiteRequest)
        } else {
            requestNeedsCostcoRefresh = true
        }
    }

    private func isCostcoDataFresh() -> Bool {
        guard let last = deps.sourceStatus().combinedLastSync else { return false }
        return deps.now().timeIntervalSince(last) <= Self.requestFreshnessWindow
    }

    // MARK: Uploading

    /// Chooses the run mode for a trigger (see header comment).
    func decideMode(for trigger: AnalyticsSyncTrigger) -> AnalyticsSyncMode {
        let status = deps.sourceStatus()
        let sourceComplete = status.onlineBackfillComplete && status.lastWarehouseSync != nil && status.lastOnlineSync != nil
        let fullDue = lastFullSyncAt.map { deps.now().timeIntervalSince($0) >= Self.fullSyncInterval } ?? true
        switch trigger {
        case .afterCostcoRefresh(partial: true), .background:
            return .incremental
        case .afterCostcoRefresh(partial: false), .manual, .websiteRequest:
            return fullDue && sourceComplete ? .full : .incremental
        }
    }

    /// Uploads local data. `forceMode` is for the developer "full check" action.
    func sync(trigger: AnalyticsSyncTrigger, forceMode: AnalyticsSyncMode? = nil) async {
        guard case .connected = connection, !isBusy else { return }
        isBusy = true
        defer {
            isBusy = false
            activity = nil
            progress = nil
        }

        if let interrupted = deps.stateStore.loadPlan() {
            activity = "Resuming previous upload…"
            // A discarded plan (expired or rejected run) is replaced by a fresh one below.
            if await runPlan(interrupted) == .stop { return }
        }

        guard let idKey = deps.secrets.read(AnalyticsSecretAccount.idKey),
              let deriver = try? AnalyticsIDDeriver(idKey: idKey)
        else {
            markRevoked()
            return
        }

        let mode = forceMode ?? decideMode(for: trigger)
        // Attach the website request only to uploads that follow fresh Costco data.
        let fulfilsRequest: Bool
        switch trigger {
        case .afterCostcoRefresh(partial: false), .websiteRequest:
            fulfilsRequest = true
        case .afterCostcoRefresh(partial: true), .manual, .background:
            fulfilsRequest = isCostcoDataFresh()
        }
        let requestId = fulfilsRequest ? pendingRequestId : nil

        activity = "Reading purchase history…"
        let snapshot: SourceSnapshot
        do {
            snapshot = try deps.snapshot()
        } catch {
            recordError("Couldn't read the purchase database. Nothing was uploaded.")
            return
        }

        activity = "Preparing upload…"
        let fingerprint = Self.keyFingerprint(idKey)
        let uploaded = deps.stateStore.loadHashes(keyFingerprint: fingerprint)
        let now = deps.now()
        let runId = AnalyticsBatchPlanner.newRunID()
        let exportedAt = AnalyticsBatchPlanner.timestamp(now)

        let prepared: (plan: AnalyticsUploadPlan, dataset: AnalyticsDataset, exclusions: [AnalyticsExclusionReason: Int])
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                () throws -> (AnalyticsUploadPlan, AnalyticsDataset, [AnalyticsExclusionReason: Int]) in
                let dataset = AnalyticsExportBuilder.build(snapshot, ids: deriver)
                var exclusions = dataset.exclusions
                let units = try AnalyticsBatchPlanner.units(for: dataset, exclusions: &exclusions)
                let plan = try AnalyticsBatchPlanner.plan(
                    units: units,
                    mode: mode,
                    uploadedHashes: uploaded,
                    requestId: requestId,
                    runId: runId,
                    exportedAt: exportedAt,
                    now: now
                )
                return (plan, dataset, exclusions)
            }.value
        } catch {
            recordError("Couldn't prepare the upload. Nothing was uploaded.")
            return
        }

        let excluded = prepared.exclusions.values.reduce(0, +)
        if excluded > 0 {
            log.notice("Analytics export excluded \(excluded, privacy: .public) row(s) that cannot be represented")
        }

        if prepared.plan.batches.isEmpty && prepared.plan.mode == .incremental && requestId == nil {
            recordSuccess(summary: "Already up to date" + Self.exclusionNote(excluded), mode: .incremental, runStatus: nil)
            return
        }

        _ = await runPlan(prepared.plan, excluded: excluded)
    }

    /// Resumes an interrupted upload, if any.
    func resumeInterruptedUpload() async {
        guard case .connected = connection, let plan = deps.stateStore.loadPlan() else { return }
        let wasBusy = isBusy
        isBusy = true
        activity = "Resuming previous upload…"
        defer {
            if !wasBusy {
                isBusy = false
                activity = nil
                progress = nil
            }
        }
        _ = await runPlan(plan)
    }

    private enum RunResult { case completed, stop, discarded }

    /// Runs a plan to completion.
    /// - completed: uploaded; - stop: try again later (offline/revoked);
    /// - discarded: the run can never finish and its plan was dropped.
    @discardableResult
    private func runPlan(_ plan: AnalyticsUploadPlan, excluded: Int = 0) async -> RunResult {
        activity = plan.mode == .full ? "Uploading (full check)…" : "Uploading…"
        do {
            let outcome = try await uploader().upload(plan) { [weak self] progress in
                self?.progress = progress
            }
            applyHashes(plan)
            if let requestId = plan.requestId, requestId == pendingRequestId {
                deps.defaults.removeObject(forKey: AnalyticsCloudDefaultsKey.pendingRequestId)
                requestNeedsCostcoRefresh = false
            }
            switch outcome {
            case .completed(let status, let pending):
                var summary = plan.batches.isEmpty
                    ? "Up to date"
                    : "Uploaded \(plan.rowCount) record\(plan.rowCount == 1 ? "" : "s")"
                if plan.mode == .full { summary += " (full check)" }
                if status == "needs_review" {
                    summary += ". \(pending) record\(pending == 1 ? "" : "s") no longer on this iPhone are waiting for your review on the website"
                }
                recordSuccess(summary: summary + Self.exclusionNote(excluded), mode: plan.mode, runStatus: status, runId: plan.runId)
            }
            return .completed
        } catch AnalyticsUploadFailure.unauthenticated {
            markRevoked()
            return .stop
        } catch AnalyticsUploadFailure.transient(let error) {
            recordError("Upload paused (\(Self.describe(error))). It will continue automatically next time.")
            return .stop
        } catch AnalyticsUploadFailure.rejected(let error) {
            if error.code == "run_not_open" {
                // The interrupted run expired server-side; nothing was lost, the next plan re-sends.
                return .discarded
            }
            recordError("CostcoTracker Analytics rejected the upload: \(Self.describe(error)). Nothing from this upload was kept.")
            deps.defaults.set(plan.runId, forKey: AnalyticsCloudDefaultsKey.lastRunId)
            deps.defaults.set("failed", forKey: AnalyticsCloudDefaultsKey.lastRunStatus)
            return .discarded
        } catch {
            recordError("Upload failed. It will be retried next time.")
            return .stop
        }
    }

    /// Developer/test hook: sets (or clears) when the last full sync happened,
    /// e.g. to force the next eligible sync to be a full check.
    func setLastFullSyncForTesting(_ date: Date?) {
        setDate(date, AnalyticsCloudDefaultsKey.lastFullSyncAt)
        lastFullSyncAt = date
    }

    private func applyHashes(_ plan: AnalyticsUploadPlan) {
        guard let idKey = deps.secrets.read(AnalyticsSecretAccount.idKey) else { return }
        let fingerprint = Self.keyFingerprint(idKey)
        var hashes = plan.replacesHashCache ? [:] : deps.stateStore.loadHashes(keyFingerprint: fingerprint)
        hashes.merge(plan.unitHashes) { _, new in new }
        try? deps.stateStore.saveHashes(hashes, keyFingerprint: fingerprint)
    }

    private func recordSuccess(summary: String, mode: AnalyticsSyncMode, runStatus: String?, runId: String? = nil) {
        let now = deps.now()
        setDate(now, AnalyticsCloudDefaultsKey.lastUploadAt)
        deps.defaults.set(summary, forKey: AnalyticsCloudDefaultsKey.lastUploadSummary)
        if mode == .full { setDate(now, AnalyticsCloudDefaultsKey.lastFullSyncAt) }
        if let runId { deps.defaults.set(runId, forKey: AnalyticsCloudDefaultsKey.lastRunId) }
        if let runStatus { deps.defaults.set(runStatus, forKey: AnalyticsCloudDefaultsKey.lastRunStatus) }
        recordError(nil)
        reloadState()
        log.info("Analytics upload finished")
    }

    // MARK: Helpers

    static func keyFingerprint(_ idKey: String) -> String {
        SHA256.hash(data: Data(idKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func exclusionNote(_ excluded: Int) -> String {
        excluded == 0 ? "" : ". \(excluded) record\(excluded == 1 ? "" : "s") couldn't be represented and were skipped"
    }

    /// Error text for the UI: server code and record paths only, never values.
    static func describe(_ error: AnalyticsAPIError) -> String {
        switch error {
        case .network:
            return "no connection"
        case .invalidResponse:
            return "unexpected response"
        case .server(let status, let code, _, _, let paths):
            let where_ = paths.isEmpty ? "" : " at " + paths.prefix(3).joined(separator: ", ")
            return "\(code), HTTP \(status)\(where_)"
        }
    }
}
