import BackgroundTasks
import Foundation

// App wiring for CostcoTracker Analytics cloud sync: the shared coordinator
// (Keychain, UserDefaults, URLSession, the live database) and best-effort
// background refresh. iOS decides if and when background refresh runs; the
// app never depends on it — launch/foreground checks do the same work.

extension AnalyticsCloudSync {
    static let shared = AnalyticsCloudSync(
        dependencies: AnalyticsCloudDependencies(
            secrets: KeychainAnalyticsSecretStore(),
            defaults: .standard,
            transport: URLSessionAnalyticsTransport(),
            stateStore: AnalyticsUploadStateStore(directory: AnalyticsUploadStateStore.defaultDirectory()),
            snapshot: { try SourceSnapshotReader.read(database: DBManager.shared.db) },
            sourceStatus: { AnalyticsCloudAppSupport.sourceStatus() }
        )
    )
}

enum AnalyticsCloudAppSupport {

    static let backgroundTaskIdentifier = "com.danmcgoldrick.CostcoTracker.analytics-refresh"

    /// The existing Costco sync's own success markers (written only when a
    /// source finished without failures) plus the online backfill flag.
    static func sourceStatus() -> AnalyticsSourceStatus {
        let defaults = UserDefaults.standard
        func date(_ key: String) -> Date? {
            let value = defaults.double(forKey: key)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        return AnalyticsSourceStatus(
            lastWarehouseSync: date("costco_last_warehouse_sync"),
            lastOnlineSync: date("costco_last_online_sync"),
            onlineBackfillComplete: DBManager.shared.isOnlineBackfillComplete()
        )
    }

    /// Must be called before the app finishes launching.
    static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: .main) { task in
            Task { @MainActor in
                scheduleBackgroundRefresh()
                let work = Task { @MainActor in
                    await AnalyticsCloudSync.shared.backgroundRefresh()
                }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: true)
            }
        }
    }

    /// Asks iOS for an occasional background check (no sooner than 4 hours).
    static func scheduleBackgroundRefresh() {
        guard case .connected = AnalyticsCloudSync.shared.connection else { return }
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
