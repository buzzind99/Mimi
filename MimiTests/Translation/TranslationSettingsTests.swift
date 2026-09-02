import Combine
import Foundation
@testable import Mimi
import Testing

/// Tests `TranslationSettings` with an isolated `UserDefaults` suite and an
/// in-memory key store, so parallel tests never share state.
@MainActor
@Suite("TranslationSettings")
struct TranslationSettingsTests {

    // MARK: - Helpers

    /// Key store whose save always fails — stands in for Keychain errors
    /// (auth denied, storage failure).
    private struct KeySaveFailed: Error {}

    private struct ThrowingKeyStore: SecureKeyStoring {
        func saveKey(_ key: String, for providerID: String) throws {
            throw KeySaveFailed()
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

        #expect(throws: (any Error).self) {
            try settings.saveKey("sk-google", for: .google)
        }
        #expect(!settings.hasKey(for: .google))
        #expect(settings.keyHint(for: .google) == nil)
        #expect(settings.testResult(for: .google) == nil)
        #expect(settings.selectedProvider == .apple)
    }

    // MARK: - Observation

    /// Locks in that `hasKey`/`keyHints`/`testResults` mutations publish:
    /// views must update on `setTestResult`/`removeKey` without incidental
    /// invalidation from a nearby `@Published` write.
    @Test("mutating keys and test results publishes objectWillChange")
    func mutationsPublishObjectWillChange() throws {
        let (settings, _) = makeSUT()
        var publishedCount = 0
        var subscriptions: [AnyCancellable] = []
        settings.objectWillChange.sink { _ in publishedCount += 1 }.store(in: &subscriptions)

        settings.setTestResult(.success, for: .google)
        #expect(publishedCount >= 1)

        publishedCount = 0
        try settings.saveKey("sk-google-1234", for: .google)
        #expect(publishedCount >= 1)

        publishedCount = 0
        settings.removeKey(for: .google)
        #expect(publishedCount >= 1)
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
}
