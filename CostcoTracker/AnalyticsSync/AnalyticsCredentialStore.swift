import Foundation
import Security

// MARK: - Secrets (Keychain)
//
// deviceToken and idKey are stored only in the Keychain, as generic passwords
// under one service, with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly:
// - available to background refresh after the first unlock,
// - never synced to iCloud Keychain and never restored onto a different
//   device from an encrypted iPhone backup ("ThisDeviceOnly").
// They are never written to UserDefaults, files, logs or CostcoTracker backups.
//
// A replacement iPhone therefore re-enrolls with a new one-time code: it gets
// its own device token, and the server returns the same instance idKey, so
// export IDs (and the cloud's records) stay identical — no duplicates.

protocol AnalyticsSecretStore {
    func read(_ account: String) -> String?
    func write(_ value: String, account: String) throws
    func delete(_ account: String) throws
}

nonisolated enum AnalyticsSecretAccount {
    static let deviceToken = "deviceToken"
    static let idKey = "idKey"
}

nonisolated struct AnalyticsKeychainError: Error, Equatable {
    var status: OSStatus
}

struct KeychainAnalyticsSecretStore: AnalyticsSecretStore {
    var service = "com.danmcgoldrick.CostcoTracker.analytics-cloud"

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw AnalyticsKeychainError(status: updateStatus) }

        var add = baseQuery(account)
        add.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AnalyticsKeychainError(status: addStatus) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AnalyticsKeychainError(status: status) }
    }
}

final class InMemoryAnalyticsSecretStore: AnalyticsSecretStore {
    private(set) var values: [String: String] = [:]
    func read(_ account: String) -> String? { values[account] }
    func write(_ value: String, account: String) throws { values[account] = value }
    func delete(_ account: String) throws { values[account] = nil }
}

// MARK: - Non-secret metadata (UserDefaults)
//
// These keys are intentionally NOT in BackupManager.backedUpDefaultsKeys, so a
// CostcoTracker backup never carries cloud connection state to another phone.

nonisolated enum AnalyticsCloudDefaultsKey {
    static let serverURL = "analytics_cloud_server_url"
    static let deviceId = "analytics_cloud_device_id"
    static let deviceName = "analytics_cloud_device_name"
    static let connectedAt = "analytics_cloud_connected_at"
    static let lastUploadAt = "analytics_cloud_last_upload_at"
    static let lastUploadSummary = "analytics_cloud_last_upload_summary"
    static let lastFullSyncAt = "analytics_cloud_last_full_sync_at"
    static let lastError = "analytics_cloud_last_error"
    static let lastErrorAt = "analytics_cloud_last_error_at"
    static let lastRunId = "analytics_cloud_last_run_id"
    static let lastRunStatus = "analytics_cloud_last_run_status"
    static let pendingRequestId = "analytics_cloud_pending_request_id"
    static let revoked = "analytics_cloud_revoked"

    static let all = [
        serverURL, deviceId, deviceName, connectedAt, lastUploadAt, lastUploadSummary, lastFullSyncAt,
        lastError, lastErrorAt, lastRunId, lastRunStatus, pendingRequestId, revoked,
    ]
}

nonisolated enum AnalyticsCloudDefaults {
    static let productionURL = URL(string: "https://costcotracker-analytics.pages.dev")!

    /// Accepts https URLs, and http only for localhost (local `wrangler pages dev`).
    static func validatedServerURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }
}

// MARK: - Upload state files (Application Support, excluded from device backups)

/// Persists the in-flight run plan (for resume) and the per-unit hashes of
/// the last successful upload (for incremental change detection).
final class AnalyticsUploadStateStore {
    private let directory: URL
    private let fileManager = FileManager.default

    struct HashCache: Codable {
        /// SHA-256 of the idKey the hashes were uploaded under; a different
        /// key (new cloud instance) invalidates the cache.
        var keyFingerprint: String
        var hashes: [String: String]
    }

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AnalyticsCloudSync", isDirectory: true)
    }

    private var planURL: URL { directory.appendingPathComponent("inflight-run.json") }
    private var hashesURL: URL { directory.appendingPathComponent("uploaded-units.json") }

    func loadPlan() -> AnalyticsUploadPlan? {
        guard let data = try? Data(contentsOf: planURL) else { return nil }
        return try? JSONDecoder().decode(AnalyticsUploadPlan.self, from: data)
    }

    func savePlan(_ plan: AnalyticsUploadPlan) throws {
        try write(try JSONEncoder().encode(plan), to: planURL)
    }

    func clearPlan() {
        try? fileManager.removeItem(at: planURL)
    }

    func loadHashes(keyFingerprint: String) -> [String: String] {
        guard let data = try? Data(contentsOf: hashesURL),
              let cache = try? JSONDecoder().decode(HashCache.self, from: data),
              cache.keyFingerprint == keyFingerprint
        else { return [:] }
        return cache.hashes
    }

    func saveHashes(_ hashes: [String: String], keyFingerprint: String) throws {
        try write(try JSONEncoder().encode(HashCache(keyFingerprint: keyFingerprint, hashes: hashes)), to: hashesURL)
    }

    func clearAll() {
        try? fileManager.removeItem(at: planURL)
        try? fileManager.removeItem(at: hashesURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableDirectory.setResourceValues(values)
        try data.write(to: url, options: [.atomic])
    }
}
