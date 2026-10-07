import SwiftUI
import UniformTypeIdentifiers

// A FileDocument wrapping an already-built backup package directory on
// disk, so SwiftUI's native .fileExporter can present the save sheet.
private struct BackupPackageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.costcoTrackerBackup] }
    static var writableContentTypes: [UTType] { [.costcoTrackerBackup] }

    let packageDirectoryURL: URL

    init(packageDirectoryURL: URL) {
        self.packageDirectoryURL = packageDirectoryURL
    }

    init(configuration: ReadConfiguration) throws {
        // Restore is handled separately via .fileImporter, which works
        // directly from a URL; FileDocument's read path is unused here.
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: packageDirectoryURL, options: [])
    }
}

struct BackupRestoreView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    @State private var exportDocument: BackupPackageDocument?
    @State private var showExporter = false
    @State private var pendingExportStagingURL: URL?

    @State private var showImporter = false
    @State private var pendingRestore: ValidatedBackup?
    @State private var showRestoreConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {

                Text(
                    "Back up your receipt history, saved price matches, and saved returns to a single file, or restore from a previous backup."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Button {
                    startBackup()
                } label: {
                    Label(
                        "Back Up CostcoTracker",
                        systemImage: "arrow.down.doc"
                    )
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)

                Button {
                    showImporter = true
                } label: {
                    Label(
                        "Restore CostcoTracker",
                        systemImage: "arrow.up.doc"
                    )
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)

                if isWorking {
                    HStack {
                        ProgressView()
                        Text("Working…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .green)
                }

                Spacer()

                Text(
                    "Backups do not include your Costco sign-in. You'll need to sign in to Costco again after restoring on a new device."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Backup & Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: exportDocument,
                contentType: .costcoTrackerBackup,
                defaultFilename: BackupManager.suggestedBackupFilename()
            ) { result in
                if let stagingURL = pendingExportStagingURL {
                    try? FileManager.default.removeItem(at: stagingURL)
                    pendingExportStagingURL = nil
                }
                exportDocument = nil

                switch result {
                case .success:
                    statusIsError = false
                    statusMessage = "Backup saved."
                case .failure(let error):
                    statusIsError = true
                    statusMessage = "Backup could not be saved: \(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.costcoTrackerBackup]
            ) { result in
                handlePickedBackup(result)
            }
            .alert(
                "Restore CostcoTracker?",
                isPresented: $showRestoreConfirmation,
                presenting: pendingRestore
            ) { validated in
                Button("Restore", role: .destructive) {
                    performRestore(validated)
                }
                Button("Cancel", role: .cancel) {
                    try? FileManager.default.removeItem(at: validated.packageURL)
                    pendingRestore = nil
                }
            } message: { validated in
                Text(
                    "This replaces your current receipt data, saved price matches, and saved returns with the contents of this backup (created \(validated.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))). This cannot be undone."
                )
            }
        }
    }

    // MARK: - Backup

    private func startBackup() {
        statusMessage = nil
        isWorking = true

        defer { isWorking = false }

        do {
            let stagingURL = try BackupManager.createBackupPackage()
            pendingExportStagingURL = stagingURL
            exportDocument = BackupPackageDocument(packageDirectoryURL: stagingURL)
            showExporter = true
        } catch {
            statusIsError = true
            statusMessage = "Backup could not be created: \(error.localizedDescription)"
        }
    }

    // MARK: - Restore

    private func handlePickedBackup(_ result: Result<URL, Error>) {
        statusMessage = nil

        switch result {
        case .failure(let error):
            statusIsError = true
            statusMessage = "Could not open the selected file: \(error.localizedDescription)"

        case .success(let url):
            do {
                let validated = try BackupManager.validateBackupPackage(at: url)
                pendingRestore = validated
                showRestoreConfirmation = true
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }

    private func performRestore(_ validated: ValidatedBackup) {
        pendingRestore = nil
        isWorking = true

        Task { @MainActor in
            defer { isWorking = false }

            do {
                try BackupManager.performRestore(validated)
                statusIsError = false
                statusMessage = "Restore complete."
            } catch {
                statusIsError = true
                statusMessage = "Restore failed: \(error.localizedDescription)"
            }
        }
    }
}
