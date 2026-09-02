import Foundation
@testable import Mimi
import Testing

/// Tests `KeychainStore` against the real Keychain, with a unique per-test
/// service name so parallel test functions never share items (Swift Testing
/// runs in parallel; the store is the unit under test, not the keychain's
/// cross-item behavior). Each test cleans up its own service via `defer`.
@Suite("KeychainStore")
struct KeychainStoreTests {

    private let providerID = "test-provider"

    // MARK: - Helpers

    /// Store scoped to a fresh service name; `deleteAll` removes everything
    /// the test created (call from `defer`).
    private func makeStore() -> (store: KeychainStore, cleanup: () -> Void) {
        let service = "dev.mimi.app.tests.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        return (store, { store.deleteKey(for: providerID) })
    }

    // MARK: - Round trip

    @Test("a saved key reads back unchanged")
    func savedKeyReadsBackUnchanged() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let apiKey = "sk-test-\(UUID().uuidString)"

        try store.saveKey(apiKey, for: providerID)

        #expect(store.readKey(for: providerID) == apiKey)
    }

    // MARK: - Overwrite

    @Test("saving over an existing key replaces it")
    func savingOverExistingKeyReplacesIt() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let originalKey = "sk-original"
        let replacementKey = "sk-replacement"

        try store.saveKey(originalKey, for: providerID)
        try store.saveKey(replacementKey, for: providerID)

        #expect(store.readKey(for: providerID) == replacementKey)
    }

    // MARK: - Delete

    @Test("delete removes the key and a second delete is a no-op")
    func deleteRemovesKeyAndIsIdempotent() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try store.saveKey("sk-gone", for: providerID)
        store.deleteKey(for: providerID)
        store.deleteKey(for: providerID)

        #expect(store.readKey(for: providerID) == nil)
    }

    // MARK: - Missing key

    @Test("reading an unconfigured provider degrades to nil")
    func missingKeyReadsAsNil() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        #expect(store.readKey(for: providerID) == nil)
    }

    // MARK: - Isolation

    @Test("keys are scoped per provider account and per service")
    func keysAreScopedPerProviderAndService() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try store.saveKey("sk-a", for: providerID)
        try store.saveKey("sk-b", for: "other-provider")
        defer { store.deleteKey(for: "other-provider") }

        #expect(store.readKey(for: providerID) == "sk-a")
        #expect(store.readKey(for: "other-provider") == "sk-b")
        #expect(store.readKey(for: "unknown-provider") == nil)
    }
}
