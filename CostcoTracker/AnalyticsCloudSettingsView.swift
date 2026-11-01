import SwiftUI
import UIKit

/// Data → CostcoTracker Analytics: connect this iPhone to the owner's
/// CostcoTracker Analytics website and upload purchase history to it.
/// Shows only non-secret status; the device token and ID key never appear.
struct AnalyticsCloudSettingsView: View {

    @ObservedObject private var cloud = AnalyticsCloudSync.shared

    @State private var code = ""
    @State private var deviceName = AnalyticsCloudSettingsView.defaultDeviceName()
    @State private var message: String?
    @State private var messageIsError = false
    @State private var confirmDisconnect = false
    @State private var serverText = ""
    @State private var showServerError = false

    var body: some View {
        Form {
            statusSection

            switch cloud.connection {
            case .connected:
                syncSection
                disconnectSection
            case .disconnected, .revoked:
                connectSection
            }

            advancedSection
        }
        .navigationTitle("CostcoTracker Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { serverText = cloud.serverURL.absoluteString }
        .confirmationDialog(
            "Disconnect this iPhone?",
            isPresented: $confirmDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                cloud.disconnect()
                showMessage("Disconnected. Also remove this iPhone under iPhones on the website so its old key stops working.", error: false)
            }
        } message: {
            Text("This iPhone stops uploading. Data already in CostcoTracker Analytics stays there.")
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            LabeledContent("Status", value: statusText)
            if case .connected(_, let name) = cloud.connection {
                LabeledContent("This iPhone", value: name ?? "iPhone")
            }
            LabeledContent("Last upload", value: cloud.lastUploadAt.map(Self.relative) ?? "Never")
            if let summary = cloud.lastUploadSummary {
                Text(summary).font(.footnote).foregroundStyle(.secondary)
            }
            if let error = cloud.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if cloud.requestNeedsCostcoRefresh {
                Text("The website asked for fresh data. Run “Sync Latest Costco Purchases”; the upload follows automatically.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(messageIsError ? .red : .green)
            }
        } footer: {
            Text("Uploads your receipts, items, returns and price adjustments to your own CostcoTracker Analytics website. Costco sign-in details, receipt barcodes and order numbers never leave this iPhone.")
        }
    }

    private var statusText: String {
        if cloud.isBusy { return cloud.activity ?? "Working…" }
        switch cloud.connection {
        case .connected: return "Connected"
        case .disconnected: return "Not connected"
        case .revoked: return "Disconnected by website"
        }
    }

    private var connectSection: some View {
        Section {
            TextField("Connection code (e.g. ABCDE-12345)", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            TextField("Name for this iPhone", text: $deviceName)
            Button {
                Task {
                    let entered = code
                    code = ""
                    if let error = await cloud.connect(code: entered, deviceName: deviceName) {
                        showMessage(error, error: true)
                    } else {
                        showMessage("Connected. Tap “Sync to Analytics” to upload your history.", error: false)
                    }
                }
            } label: {
                if cloud.isBusy { ProgressView() } else { Text("Connect") }
            }
            .disabled(cloud.isBusy || code.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Connect")
        } footer: {
            Text("On the CostcoTracker Analytics website, open iPhones → Create connection code, then enter it here within 10 minutes. Each code works once.")
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                Task {
                    await cloud.sync(trigger: .manual)
                    message = nil
                }
            } label: {
                HStack {
                    Text("Sync to Analytics")
                    Spacer()
                    if cloud.isBusy {
                        if let progress = cloud.progress, progress.batchCount > 0 {
                            Text("\(progress.batchesSent)/\(progress.batchCount)").font(.caption).monospacedDigit()
                        }
                        ProgressView()
                    }
                }
            }
            .disabled(cloud.isBusy)
        } footer: {
            Text("Uploads also happen automatically after each successful Costco sync. A full check runs about once a week; the website asks you before removing anything that disappeared from this iPhone.")
        }
    }

    private var disconnectSection: some View {
        Section {
            Button("Disconnect This iPhone", role: .destructive) { confirmDisconnect = true }
                .disabled(cloud.isBusy)
        }
    }

    private var advancedSection: some View {
        Section {
            LabeledContent("Server", value: cloud.serverURL.host ?? cloud.serverURL.absoluteString)
            if case .connected(let deviceId, _) = cloud.connection {
                LabeledContent("Device ID", value: deviceId)
            }
            LabeledContent("Last full check", value: cloud.lastFullSyncAt.map(Self.relative) ?? "Never")
            if let status = cloud.lastRunStatus {
                LabeledContent("Last run", value: status)
            }
            if cloud.hasInterruptedUpload {
                Text("An interrupted upload will resume automatically.").font(.footnote)
            }

            if case .connected = cloud.connection {
                Button("Run Full Check Now") {
                    Task { await cloud.sync(trigger: .manual, forceMode: .full) }
                }
                .disabled(cloud.isBusy)
                Button("Check for Website Requests") {
                    Task { await cloud.checkSyncRequests(allowUpload: true) }
                }
                .disabled(cloud.isBusy)
            } else {
                TextField("Server URL", text: $serverText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use This Server") {
                    if cloud.setServerURL(serverText) {
                        serverText = cloud.serverURL.absoluteString
                        showMessage("Server set to \(cloud.serverURL.absoluteString).", error: false)
                    } else {
                        showMessage("Enter an https:// address (or http://localhost for local testing).", error: true)
                    }
                }
                Button("Use Production Server") {
                    cloud.setServerURL("")
                    serverText = cloud.serverURL.absoluteString
                }
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("The server can only be changed while disconnected. The connection key is stored in the iOS Keychain on this iPhone only and is never shown.")
        }
    }

    // MARK: Helpers

    private func showMessage(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// iOS reports a generic name ("iPhone") without a special entitlement;
    /// the user can edit it before connecting.
    private static func defaultDeviceName() -> String {
        let name = UIDevice.current.name
        return name.isEmpty ? "iPhone" : String(name.prefix(60))
    }
}
