import Foundation
@testable import Mimi
import Security
import Testing

/// Tests `TranslationSettings` with an isolated `UserDefaults` suite and an
/// in-memory key store, so parallel tests never share state.
@MainActor
@Suite("TranslationSettings")
struct TranslationSettingsTests {

    // MARK: - Helpers

    /// Key store whose save always fails — stands in for Keychain errors
    /// (auth denied, storage failure).
    private struct ThrowingKeyStore: SecureKeyStoring {
        func saveKey(_ key: String, for providerID: String) throws(KeychainStoreError) {
            throw KeychainStoreError(status: errSecAuthFailed)
        }

        func readKey(for providerID: String) -> String? {
            nil
        }

        func deleteKey(for providerID: String) {}
    }

    private func makeSUT(
        defaults: UserDefaults? = nil,
        keys: SecureKeyStoring = InMemoryKeyStore()
    ) -> (settings: TranslationSettings, defaults: UserDefaults) {
        let suiteName = "test.TranslationSettings.\(UUID().uuidString)"
        let defaults = defaults ?? UserDefaults(suiteName: suiteName)!
        return (TranslationSettings(defaults: defaults, keys: keys), defaults)
    }

    // MARK: - Defaults

    @Test("fresh settings default to Apple with no keys")
    func freshDefaults() {
        let (settings, _) = makeSUT()

        #expect(settings.selectedProvider == .apple)
        #expect(!settings.hasKey(for: .google))
        #expect(settings.key(for: .google) == nil)
        #expect(settings.openRouterModel.isEmpty)
    }

    @Test("previously persisted selection and model load back")
    func persistedStateLoads() {
        let (first, defaults) = makeSUT()
        first.select(.openrouter)
        first.openRouterModel = "tencent/hy-mt2-30b-a3b"

        let (second, _) = makeSUT(defaults: defaults)

        #expect(second.selectedProvider == .openrouter)
        #expect(second.openRouterModel == "tencent/hy-mt2-30b-a3b")
    }

    @Test("invalid persisted provider raw value degrades to Apple")
    func invalidPersistedProviderDegradesToApple() throws {
        let suiteName = "test.TranslationSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set("not-a-provider", forKey: "translation.selectedProvider")

        let (settings, _) = makeSUT(defaults: defaults)

        #expect(settings.selectedProvider == .apple)
    }

    // MARK: - Key save / remove

    @Test("saving a key stores it in the secure store and sets the flag")
    func savingKeyStoresAndFlags() throws {
        let (settings, _) = makeSUT()

        try settings.saveKey("sk-google-1234", for: .google)

        #expect(settings.hasKey(for: .google))
        #expect(settings.key(for: .google) == "sk-google-1234")
        #expect(settings.keyHint(for: .google) == "1234")
    }

    @Test("saving a key for an external provider switches the selection to it")
    func savingExternalKeySwitchesSelection() throws {
        let (settings, _) = makeSUT()

        try settings.saveKey("sk-deepl", for: .deepl)

        #expect(settings.selectedProvider == .deepl)
    }

    @Test("saving a DeepL free-tier key records the tier")
    func deeplFreeTierDetected() throws {
        let (settings, _) = makeSUT()

        try settings.saveKey("abc123:fx", for: .deepl)

        #expect(settings.deeplIsFreeTier)
        #expect(settings.activeEngineDescription(fallbackActive: false) == "DeepL (Free)")
    }

    @Test("removing a key clears the flag, hint, key, and test result")
    func removingKeyClearsEverything() throws {
        let (settings, _) = makeSUT()
        try settings.saveKey("sk-google-9999", for: .google)
        settings.setTestResult(.success, for: .google)

        settings.removeKey(for: .google)

        #expect(!settings.hasKey(for: .google))
        #expect(settings.key(for: .google) == nil)
        #expect(settings.keyHint(for: .google) == nil)
        #expect(settings.testResult(for: .google) == nil)
    }

    @Test("a stored hasKey flag without a backing key degrades to no key")
    func staleFlagWithoutKeyDegrades() throws {
        let (first, defaults) = makeSUT()
        try first.saveKey("sk-google", for: .google)

        // Rebuild with a store that has nothing for google.
        let (second, _) = makeSUT(defaults: defaults, keys: InMemoryKeyStore())

        #expect(!second.hasKey(for: .google))
    }

    @Test("a failed key save surfaces the error and mutates nothing")
    func failedSaveSurfacesErrorAndMutatesNothing() {
        let (settings, _) = makeSUT(keys: ThrowingKeyStore())

        #expect(throws: KeychainStoreError.self) {
            try settings.saveKey("sk-google", for: .google)
        }
        #expect(!settings.hasKey(for: .google))
        #expect(settings.keyHint(for: .google) == nil)
        #expect(settings.testResult(for: .google) == nil)
        #expect(settings.selectedProvider == .apple)
    }

    // MARK: - Observation

    /// Locks in that `hasKey`/`keyHints`/`testResults` mutations are observed
    /// by tracking readers: views must update on `setTestResult`/`removeKey`.
    /// Each recorder pins the dictionary property the UI actually reads.
    /// The recorder's read hops to the main actor post-mutation, so each
    /// mutation is followed by a settle.
    @Test("mutating keys and test results is observed by tracking readers")
    func mutationsAreObserved() async throws {
        let (settings, _) = makeSUT()
        let hasKeyRecorder = ObservedValuesRecorder(read: { settings.hasKey[.google] ?? false })
        let keyHintsRecorder = ObservedValuesRecorder(read: { settings.keyHints[.google] })
        let testResultsRecorder = ObservedValuesRecorder(read: { settings.testResult(for: .google) })
        func settle() async {
            for _ in 0 ..< 20 {
                await Task.yield()
            }
        }

        settings.setTestResult(.success, for: .google)
        await settle()
        #expect(testResultsRecorder.values == [.success])
        #expect(hasKeyRecorder.values.isEmpty)
        #expect(keyHintsRecorder.values.isEmpty)

        try settings.saveKey("sk-google-1234", for: .google)
        await settle()
        #expect(hasKeyRecorder.values == [true])
        #expect(keyHintsRecorder.values == ["1234"])

        settings.removeKey(for: .google)
        await settle()
        #expect(hasKeyRecorder.values == [true, false])
        #expect(keyHintsRecorder.values == ["1234", nil])
    }

    // MARK: - Selection persistence

    @Test("select persists the provider choice")
    func selectPersists() {
        let (first, defaults) = makeSUT()
        first.select(.google)

        let (second, _) = makeSUT(defaults: defaults)

        #expect(second.selectedProvider == .google)
    }

    // MARK: - Test results

    @Test("test results persist across relaunch")
    func resultsPersist() {
        let (first, defaults) = makeSUT()
        first.setTestResult(.success, for: .google)
        first.setTestResult(.failure("Invalid API key"), for: .deepl)

        let (second, _) = makeSUT(defaults: defaults)

        #expect(second.testResult(for: .google) == .success)
        #expect(second.testResult(for: .deepl) == .failure("Invalid API key"))
    }

    // MARK: - Active engine description

    @Test("active engine description reflects each provider")
    func activeEngineDescriptionVariants() throws {
        let (settings, _) = makeSUT()

        #expect(settings.activeEngineDescription(fallbackActive: false) == "Apple (on-device)")

        try settings.saveKey("sk-openrouter", for: .openrouter)
        settings.openRouterModel = "tencent/hy-mt2-30b-a3b"

        #expect(settings.activeEngineDescription(fallbackActive: false) == "OpenRouter · tencent/hy-mt2-30b-a3b")
    }

    @Test("fallback latch appends the fallback note only for external providers")
    func fallbackNoteOnlyForExternal() throws {
        let (settings, _) = makeSUT()
        try settings.saveKey("sk-google", for: .google)

        #expect(settings.activeEngineDescription(fallbackActive: true) == "Google Translate — fallback active")
    }

    // MARK: - Provider metadata

    /// Raw values are Keychain account names and UserDefaults keys — this
    /// locks them (and the picker labels) against accidental renames.
    @Test("provider raw values and display names stay stable")
    func providerIdentityAndDisplayNames() {
        #expect(TranslationProvider.allCases.map(\.id) == ["apple", "google", "deepl", "openrouter"])
        #expect(TranslationProvider.apple.displayName == "Apple (on-device)")
        #expect(TranslationProvider.google.displayName == "Google Translate")
        #expect(TranslationProvider.deepl.displayName == "DeepL")
        #expect(TranslationProvider.openrouter.displayName == "OpenRouter")
    }

    // MARK: - Short keys

    @Test("a key too short for a hint clears any stale hint")
    func shortKeyClearsStaleHint() throws {
        let (settings, _) = makeSUT()
        try settings.saveKey("sk-google-9999", for: .google)
        #expect(settings.keyHint(for: .google) == "9999")

        try settings.saveKey("", for: .google)

        #expect(settings.keyHint(for: .google) == nil)
    }

    // MARK: - Garbage persistence

    @Test("a garbage persisted test result degrades to nil")
    func garbageTestResultDegrades() throws {
        let suiteName = "test.TranslationSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set("garbage", forKey: "translation.testResult.google")

        let (settings, _) = makeSUT(defaults: defaults)

        #expect(settings.testResult(for: .google) == nil)
    }
}
