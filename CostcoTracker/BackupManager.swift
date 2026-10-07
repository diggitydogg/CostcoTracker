import Foundation
import SQLite3
import UniformTypeIdentifiers

// MARK: - Backup Format

extension UTType {
    static var costcoTrackerBackup: UTType {
        UTType(exportedAs: "com.danmcgoldrick.costcotracker.backup")
    }
}

struct BackupManifest: Codable {
    var backupFormatVersion: Int
    var appVersion: String
    var appBuildNumber: String
    var createdAt: Date
    var databaseSchemaVersion: Int
}

enum BackupError: LocalizedError {
    case databaseUnavailable
    case manifestMissing
    case manifestUnreadable
    case unsupportedFormatVersion(Int)
    case databaseMissing
    case databaseInvalid
    case databaseCorrupt

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "The CostcoTracker database could not be accessed."
        case .manifestMissing:
            return "This file doesn't contain a CostcoTracker backup manifest."
        case .manifestUnreadable:
            return "The backup manifest could not be read."
        case .unsupportedFormatVersion(let version):
            return "This backup (format version \(version)) isn't supported by this version of CostcoTracker."
        case .databaseMissing:
            return "This backup is missing its database contents."
        case .databaseInvalid:
            return "This backup's database could not be verified."
        case .databaseCorrupt:
            return "This backup's database failed an integrity check and may be corrupted."
        }
    }
}

struct ValidatedBackup {
    let manifest: BackupManifest
    let packageURL: URL
}

// Value stored for one UserDefaults key inside a backup. Price Match Queue
// and Saved Returns are stored as JSON-encoded Data; the sync timestamps
// are plain Double values. Keeping both shapes explicit avoids ambiguity
// on restore.
private enum StoredDefaultValue: Codable {
    case data(Data)
    case double(Double)

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    private enum Kind: String, Codable {
        case data, double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .data:
            self = .data(try container.decode(Data.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .data(let data):
            try container.encode(Kind.data, forKey: .kind)
            try container.encode(data, forKey: .value)
        case .double(let double):
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(double, forKey: .value)
        }
    }
}

// MARK: - Backup Manager

// Builds and restores a versioned CostcoTracker backup package. The package
// is a real directory on disk (declared to the system as a package-type
// UTType, same mechanism Apple document bundles like .rtfd use), containing:
//
//   manifest.json
//   database/costco.db
//   local-state/user-defaults.json
//   return-photos/*
//
// Intentionally excluded: Costco authentication cookies/session state
// (WKWebView's website data store, never touched here), caches, and any
// temporary/derived files.
enum BackupManager {

    static let backupFormatVersion = 1

    private static let databaseFolderName = "database"
    private static let localStateFolderName = "local-state"
    private static let returnPhotosFolderName = "return-photos"
    private static let manifestFileName = "manifest.json"
    private static let databaseFileName = "costco.db"
    private static let userDefaultsFileName = "user-defaults.json"

    // Every genuinely user-created UserDefaults-backed key discovered in
    // the persistence audit. Deliberately excludes nothing Costco-auth
    // related, because no such state lives in UserDefaults.
    private static let backedUpDefaultsKeys = [
        "costco_price_match_queue",
        "costco_saved_returns",
        "costco_last_successful_sync",
        "costco_last_warehouse_sync",
        "costco_last_online_sync",
    ]

    private static let requiredDatabaseTables = [
        "receipts", "items", "price_adjustments", "item_returns",
    ]

    // MARK: Backup

    /// Builds a complete backup package in a fresh temporary directory and
    /// returns its URL. The caller is responsible for removing it once the
    /// export flow (success or cancel) has finished with it.
    static func createBackupPackage() throws -> URL {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostcoTrackerBackup-\(UUID().uuidString)", isDirectory: true)

        let databaseDir = stagingRoot.appendingPathComponent(databaseFolderName, isDirectory: true)
        let localStateDir = stagingRoot.appendingPathComponent(localStateFolderName, isDirectory: true)
        let photosDir = stagingRoot.appendingPathComponent(returnPhotosFolderName, isDirectory: true)

        try FileManager.default.createDirectory(at: databaseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localStateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)

        let schemaVersion = try snapshotDatabase(
            into: databaseDir.appendingPathComponent(databaseFileName)
        )

        try snapshotUserDefaults(
            into: localStateDir.appendingPathComponent(userDefaultsFileName)
        )

        try snapshotReturnPhotos(into: photosDir)

        let manifest = BackupManifest(
            backupFormatVersion: backupFormatVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            createdAt: Date(),
            databaseSchemaVersion: schemaVersion
        )

        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: stagingRoot.appendingPathComponent(manifestFileName), options: .atomic)

        return stagingRoot
    }

    static func suggestedBackupFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "CostcoTracker-\(formatter.string(from: Date()))"
    }

    // Uses SQLite's online backup API to take a transactionally consistent
    // snapshot of the live database, rather than copying the file on disk
    // directly (which could race an in-progress write regardless of
    // journal mode).
    private static func snapshotDatabase(into destinationURL: URL) throws -> Int {
        guard let sourceDB = DBManager.shared.db else {
            throw BackupError.databaseUnavailable
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        var destinationDB: OpaquePointer?
        guard sqlite3_open(destinationURL.path, &destinationDB) == SQLITE_OK else {
            sqlite3_close(destinationDB)
            throw BackupError.databaseUnavailable
        }

        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            sqlite3_close(destinationDB)
            throw BackupError.databaseUnavailable
        }

        let stepResult = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        sqlite3_close(destinationDB)

        guard stepResult == SQLITE_DONE else {
            throw BackupError.databaseUnavailable
        }

        var schemaVersion: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(sourceDB, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                schemaVersion = sqlite3_column_int(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)

        return Int(schemaVersion)
    }

    private static func snapshotUserDefaults(into destinationURL: URL) throws {
        let defaults = UserDefaults.standard
        var values: [String: StoredDefaultValue] = [:]

        for key in backedUpDefaultsKeys {
            if let data = defaults.data(forKey: key) {
                values[key] = .data(data)
            } else if defaults.object(forKey: key) != nil {
                values[key] = .double(defaults.double(forKey: key))
            }
        }

        let payload = try JSONEncoder().encode(values)
        try payload.write(to: destinationURL, options: .atomic)
    }

    private static func returnPhotosSourceDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ReturnProductPhotos", isDirectory: true)
    }

    private static func snapshotReturnPhotos(into destinationDir: URL) throws {
        let source = returnPhotosSourceDirectory()
        guard FileManager.default.fileExists(atPath: source.path) else {
            return
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil
        )

        for fileURL in contents {
            let destination = destinationDir.appendingPathComponent(fileURL.lastPathComponent)
            try FileManager.default.copyItem(at: fileURL, to: destination)
        }
    }

    // MARK: Restore — Validation

    /// Copies the picked backup into app-sandboxed temporary storage and
    /// validates it. Does not touch any live app data. Throws a
    /// `BackupError` describing exactly what's wrong with a malformed or
    /// unsupported backup.
    static func validateBackupPackage(at pickedURL: URL) throws -> ValidatedBackup {
        let didAccess = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { pickedURL.stopAccessingSecurityScopedResource() }
        }

        let workingCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostcoTrackerRestore-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.copyItem(at: pickedURL, to: workingCopy)

        do {
            let manifestURL = workingCopy.appendingPathComponent(manifestFileName)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                throw BackupError.manifestMissing
            }

            guard
                let manifestData = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONDecoder().decode(BackupManifest.self, from: manifestData)
            else {
                throw BackupError.manifestUnreadable
            }

            guard manifest.backupFormatVersion == backupFormatVersion else {
                throw BackupError.unsupportedFormatVersion(manifest.backupFormatVersion)
            }

            let databaseURL = workingCopy
                .appendingPathComponent(databaseFolderName)
                .appendingPathComponent(databaseFileName)

            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw BackupError.databaseMissing
            }

            try validateDatabaseContents(at: databaseURL)

            return ValidatedBackup(manifest: manifest, packageURL: workingCopy)

        } catch {
            try? FileManager.default.removeItem(at: workingCopy)
            throw error
        }
    }

    // Opens the staged database read-only and verifies it both contains the
    // tables this app expects AND passes `PRAGMA integrity_check`. Rejects
    // a corrupt or unexpected database before any live state is touched.
    private static func validateDatabaseContents(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw BackupError.databaseInvalid
        }
        defer { sqlite3_close(db) }

        for table in requiredDatabaseTables {
            var stmt: OpaquePointer?
            let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;"

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw BackupError.databaseInvalid
            }

            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = table.withCString { pointer in
                sqlite3_bind_text(stmt, 1, pointer, -1, transient)
            }

            let found = sqlite3_step(stmt) == SQLITE_ROW
            sqlite3_finalize(stmt)

            guard found else { throw BackupError.databaseInvalid }
        }

        guard passesIntegrityCheck(db) else {
            throw BackupError.databaseCorrupt
        }
    }

    private static func passesIntegrityCheck(_ db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return false
        }
        defer { sqlite3_finalize(stmt) }

        guard
            sqlite3_step(stmt) == SQLITE_ROW,
            let resultPointer = sqlite3_column_text(stmt, 0)
        else {
            return false
        }

        return String(cString: resultPointer).lowercased() == "ok"
    }

    // MARK: Restore — Apply

    /// Replaces the live database, UserDefaults-backed state, and Saved
    /// Return photos with the contents of a previously validated backup.
    ///
    /// Sequence: capture a complete rollback snapshot of every component
    /// this restore will touch (DB via the online backup API while the
    /// live connection is still open, UserDefaults — preserving which keys
    /// were present vs. absent — and the full return-photos directory)
    /// *before* any mutation begins. Only then close the DB and apply the
    /// backup's DB + UserDefaults + photos. If any single step fails, every
    /// component is restored from the rollback snapshot, the DB connection
    /// is reopened, and the stores are reloaded, before rethrowing — so a
    /// failed restore is atomic from the user's perspective and never
    /// leaves a mix of old and new state. Temporary staging/rollback
    /// directories are removed on both success and failure.
    @MainActor
    static func performRestore(_ validated: ValidatedBackup) throws {
        defer { try? FileManager.default.removeItem(at: validated.packageURL) }

        guard let liveDatabaseURL = DBManager.databaseFileURL() else {
            throw BackupError.databaseUnavailable
        }

        let rollbackRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostcoTrackerRollback-\(UUID().uuidString)", isDirectory: true)
        let rollbackDatabaseDir = rollbackRoot.appendingPathComponent(databaseFolderName, isDirectory: true)
        let rollbackLocalStateDir = rollbackRoot.appendingPathComponent(localStateFolderName, isDirectory: true)
        let rollbackPhotosDir = rollbackRoot.appendingPathComponent(returnPhotosFolderName, isDirectory: true)
        let rollbackDatabaseURL = rollbackDatabaseDir.appendingPathComponent(databaseFileName)
        let rollbackUserDefaultsURL = rollbackLocalStateDir.appendingPathComponent(userDefaultsFileName)

        try FileManager.default.createDirectory(at: rollbackDatabaseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollbackLocalStateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollbackPhotosDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: rollbackRoot) }

        // Complete rollback snapshot, captured before any mutation. The DB
        // snapshot uses the online backup API against the still-open live
        // connection — never a raw copy of the live file.
        _ = try snapshotDatabase(into: rollbackDatabaseURL)
        try snapshotUserDefaults(into: rollbackUserDefaultsURL)
        try snapshotReturnPhotos(into: rollbackPhotosDir)

        DBManager.shared.closeDatabase()

        do {
            if FileManager.default.fileExists(atPath: liveDatabaseURL.path) {
                try FileManager.default.removeItem(at: liveDatabaseURL)
            }

            let stagedDatabaseURL = validated.packageURL
                .appendingPathComponent(databaseFolderName)
                .appendingPathComponent(databaseFileName)

            try FileManager.default.copyItem(at: stagedDatabaseURL, to: liveDatabaseURL)

            // A restored file should never carry over a stale rollback
            // journal / WAL sidecar from wherever it was created.
            for suffix in ["-journal", "-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: liveDatabaseURL.path + suffix)
                try? FileManager.default.removeItem(at: sidecar)
            }

            try restoreUserDefaults(
                from: validated.packageURL
                    .appendingPathComponent(localStateFolderName)
                    .appendingPathComponent(userDefaultsFileName)
            )

            try restoreReturnPhotos(
                from: validated.packageURL.appendingPathComponent(returnPhotosFolderName)
            )

            DBManager.shared.openDatabase()
            PriceMatchQueue.shared.reload()
            SavedReturnStore.shared.reload()

        } catch {
            rollBackAllState(
                liveDatabaseURL: liveDatabaseURL,
                rollbackDatabaseURL: rollbackDatabaseURL,
                rollbackUserDefaultsURL: rollbackUserDefaultsURL,
                rollbackPhotosDir: rollbackPhotosDir
            )
            throw error
        }
    }

    // Restores the database file, UserDefaults-backed keys, and the Saved
    // Return photos directory from a previously captured rollback snapshot,
    // then reopens the DB connection and reloads the in-memory stores so
    // the UI reflects the restored-to-original state. Used whenever a
    // restore fails partway through.
    @MainActor
    private static func rollBackAllState(
        liveDatabaseURL: URL,
        rollbackDatabaseURL: URL,
        rollbackUserDefaultsURL: URL,
        rollbackPhotosDir: URL
    ) {
        try? FileManager.default.removeItem(at: liveDatabaseURL)
        if FileManager.default.fileExists(atPath: rollbackDatabaseURL.path) {
            try? FileManager.default.copyItem(at: rollbackDatabaseURL, to: liveDatabaseURL)
        }

        try? restoreUserDefaults(from: rollbackUserDefaultsURL)
        try? restoreReturnPhotos(from: rollbackPhotosDir)

        DBManager.shared.openDatabase()
        PriceMatchQueue.shared.reload()
        SavedReturnStore.shared.reload()
    }

    private static func restoreUserDefaults(from url: URL) throws {
        let defaults = UserDefaults.standard

        guard FileManager.default.fileExists(atPath: url.path) else {
            for key in backedUpDefaultsKeys {
                defaults.removeObject(forKey: key)
            }
            return
        }

        let data = try Data(contentsOf: url)
        let values = try JSONDecoder().decode([String: StoredDefaultValue].self, from: data)

        for key in backedUpDefaultsKeys {
            guard let value = values[key] else {
                defaults.removeObject(forKey: key)
                continue
            }

            switch value {
            case .data(let data):
                defaults.set(data, forKey: key)
            case .double(let double):
                defaults.set(double, forKey: key)
            }
        }
    }

    // Clears only the *contents* of the photos directory rather than
    // removing and recreating the directory entry itself. Removing the
    // directory entry requires write access to its parent, which isn't
    // guaranteed; a partial failure there (contents gone, directory entry
    // left behind) would also break a subsequent rollback attempt that
    // uses this same function. Operating on contents only needs write
    // access to the directory itself, and fails cleanly before deleting
    // anything if that's unavailable.
    private static func restoreReturnPhotos(from sourceDir: URL) throws {
        let destination = returnPhotosSourceDirectory()

        if FileManager.default.fileExists(atPath: destination.path) {
            let existingContents = try FileManager.default.contentsOfDirectory(
                at: destination, includingPropertiesForKeys: nil
            )
            for fileURL in existingContents {
                try FileManager.default.removeItem(at: fileURL)
            }
        } else {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        guard FileManager.default.fileExists(atPath: sourceDir.path) else {
            return
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: sourceDir, includingPropertiesForKeys: nil
        )

        for fileURL in contents {
            let destinationURL = destination.appendingPathComponent(fileURL.lastPathComponent)
            try FileManager.default.copyItem(at: fileURL, to: destinationURL)
        }
    }
}
