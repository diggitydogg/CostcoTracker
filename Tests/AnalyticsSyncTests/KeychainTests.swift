import Foundation
import Security
import Testing
@testable import AnalyticsSync

@Suite("Keychain secret store")
struct KeychainTests {

    @Test("Writes, overwrites, survives a new store instance (relaunch), and deletes")
    func roundTrip() throws {
        let service = "com.danmcgoldrick.CostcoTracker.analytics-cloud.tests.\(UUID().uuidString)"
        let store = KeychainAnalyticsSecretStore(service: service)
        defer { try? store.delete("deviceToken") }

        do {
            try store.write("first-value", account: "deviceToken")
        } catch let error as AnalyticsKeychainError
            where error.status == errSecMissingEntitlement || error.status == errSecInteractionNotAllowed || error.status == errSecNotAvailable {
            // Headless CI machines sometimes have no usable keychain. Record it
            // visibly instead of silently passing.
            withKnownIssue("Keychain unavailable in this test environment (OSStatus \(error.status))") {
                throw error
            }
            return
        }

        #expect(store.read("deviceToken") == "first-value")
        try store.write("second-value", account: "deviceToken")
        #expect(KeychainAnalyticsSecretStore(service: service).read("deviceToken") == "second-value")
        #expect(store.read("idKey") == nil)

        try store.delete("deviceToken")
        #expect(store.read("deviceToken") == nil)
        try store.delete("deviceToken") // deleting a missing item is fine
    }

    @Test("A connected coordinator survives relaunch with the real Keychain")
    func coordinatorWithKeychain() async throws {
        let service = "com.danmcgoldrick.CostcoTracker.analytics-cloud.tests.\(UUID().uuidString)"
        let store = KeychainAnalyticsSecretStore(service: service)
        defer {
            try? store.delete(AnalyticsSecretAccount.deviceToken)
            try? store.delete(AnalyticsSecretAccount.idKey)
        }
        do {
            try store.write("probe", account: "probe")
            try store.delete("probe")
        } catch {
            withKnownIssue("Keychain unavailable in this test environment") { throw error }
            return
        }

        let h = try Harness.make(secrets: store)
        try await h.connect()
        let relaunched = h.relaunched()
        guard case .connected = relaunched.connection else { Issue.record("not connected after relaunch"); return }
        #expect(store.read(AnalyticsSecretAccount.idKey) == Fixtures.idKey)
    }
}
