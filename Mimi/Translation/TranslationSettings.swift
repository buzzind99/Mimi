import Combine
import Foundation

/// Translation providers selectable behind the `TranslationQueue` seam.
/// Raw values are the Keychain account names and UserDefaults keys, so they
/// must stay stable.
enum TranslationProvider: String, CaseIterable, Codable, Identifiable {
    case apple
    case google
    case deepl
    case openrouter

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .apple: "Apple (on-device)"
        case .google: "Google Translate"
        case .deepl: "DeepL"
        case .openrouter: "OpenRouter"
        }
    }

    /// Cloud providers send transcript sentences off the machine.
    var isExternal: Bool {
        self != .apple
    }
}

/// Outcome of the Settings "Test" button, surfaced inline and persisted so
/// the row survives relaunch. Failure detail strings are provider-agnostic
/// status copy — never key material or raw response bodies.
enum ConnectionTestResult: Equatable {
    case success
    case failure(String)
}

/// Non-secret translation settings: selected provider, per-provider `hasKey`
/// flags (with a last-4 hint for the UI), the OpenRouter model string, and
/// the latest connection-test results. Keys themselves live only in
/// `SecureKeyStoring` (the Keychain in production) and are read on demand
/// when an engine is constructed — never cached here.
///
/// Auto-default policy: saving a key for an external provider switches the
/// selection to it; Apple on-device stays active until any external provider
/// is configured.
@MainActor
final class TranslationSettings: ObservableObject {
    @Published private(set) var selectedProvider: TranslationProvider {
        didSet { defaults.set(selectedProvider.rawValue, forKey: Self.selectedKey) }
    }

    /// OpenRouter chat-completions model, used verbatim in the request body.
    @Published var openRouterModel: String {
        didSet { defaults.set(openRouterModel, forKey: Self.openRouterModelKey) }
    }

    /// True when the selected DeepL key came from the free tier (`:fx`
    /// suffix) — drives the "DeepL (Free)" label. Non-secret.
    @Published private(set) var deeplIsFreeTier: Bool {
        didSet { defaults.set(deeplIsFreeTier, forKey: Self.deeplFreeKey) }
    }

    /// Published so views update on `removeKey`/`setTestResult` without
    /// incidental invalidation; subscript assignment routes through the
    /// setter, firing `objectWillChange`.
    @Published private(set) var hasKey: [TranslationProvider: Bool]
    @Published private(set) var keyHints: [TranslationProvider: String]
    @Published private(set) var testResults: [TranslationProvider: ConnectionTestResult]

    private let defaults: UserDefaults
    private let keys: SecureKeyStoring

    private static let selectedKey = "translation.selectedProvider"
    private static let openRouterModelKey = "translation.openRouterModel"
    private static let deeplFreeKey = "translation.deeplFreeTier"
    private static func hasKeyKey(_ provider: TranslationProvider) -> String {
        "translation.hasKey.\(provider.rawValue)"
    }

    private static func keyHintKey(_ provider: TranslationProvider) -> String {
        "translation.keyHint.\(provider.rawValue)"
    }

    private static func testResultKey(_ provider: TranslationProvider) -> String {
        "translation.testResult.\(provider.rawValue)"
    }

    /// - Parameters:
    ///   - defaults: injectable for tests (unique suite per test).
    ///   - keys: injectable for tests (in-memory stand-in for the Keychain).
    ///     Nil (production default) uses the Keychain in release builds; dev
    ///     builds get a no-op store instead — the dev-signed binary can't
    ///     read items saved by the release app, so every Keychain read would
    ///     pop an access prompt. With no readable key, dev always runs the
    ///     Apple on-device engine.
    init(defaults: UserDefaults = .standard, keys: (any SecureKeyStoring)? = nil) {
        self.defaults = defaults
        #if DEBUG
            self.keys = keys ?? DevNoopKeyStore()
        #else
            self.keys = keys ?? KeychainStore()
        #endif

        let selected = defaults.string(forKey: Self.selectedKey)
            .flatMap(TranslationProvider.init(rawValue:)) ?? .apple
        selectedProvider = selected
        openRouterModel = defaults.string(forKey: Self.openRouterModelKey) ?? ""
        deeplIsFreeTier = defaults.bool(forKey: Self.deeplFreeKey)

        var hasKey: [TranslationProvider: Bool] = [:]
        var keyHints: [TranslationProvider: String] = [:]
        var testResults: [TranslationProvider: ConnectionTestResult] = [:]
        for provider in TranslationProvider.allCases {
            let stored = defaults.bool(forKey: Self.hasKeyKey(provider))
            // Cross-check the flag against the actual key store: a flag
            // without a key (or vice versa) degrades to the truth.
            hasKey[provider] = stored && self.keys.readKey(for: provider.rawValue) != nil
            keyHints[provider] = defaults.string(forKey: Self.keyHintKey(provider))
            if let raw = defaults.string(forKey: Self.testResultKey(provider)) {
                testResults[provider] = Self.decodeTestResult(raw)
            }
        }
        self.hasKey = hasKey
        self.keyHints = keyHints
        self.testResults = testResults
    }

    // MARK: - Key management

    func hasKey(for provider: TranslationProvider) -> Bool {
        hasKey[provider] ?? false
    }

    /// Last-4 hint shown after saving ("•••• ab12"). Nil when unconfigured.
    func keyHint(for provider: TranslationProvider) -> String? {
        keyHints[provider]
    }

    /// Reads the key from the secure store on demand (engine construction,
    /// connection tests). Never cached.
    func key(for provider: TranslationProvider) -> String? {
        guard hasKey(for: provider) else { return nil }
        return keys.readKey(for: provider.rawValue)
    }

    /// Writes the key to the secure store, records the non-secret `hasKey`
    /// flag + last-4 hint, and applies the auto-default policy: an external
    /// provider with a key becomes the selected provider.
    func saveKey(_ key: String, for provider: TranslationProvider) throws(KeychainStoreError) {
        try keys.saveKey(key, for: provider.rawValue)
        hasKey[provider] = true
        let suffix = key.suffix(4)
        keyHints[provider] = suffix.isEmpty ? nil : String(suffix)
        defaults.set(true, forKey: Self.hasKeyKey(provider))
        if suffix.isEmpty {
            defaults.removeObject(forKey: Self.keyHintKey(provider))
        } else {
            defaults.set(String(suffix), forKey: Self.keyHintKey(provider))
        }
        if provider == .deepl {
            deeplIsFreeTier = key.hasSuffix(":fx")
        }
        if provider.isExternal {
            select(provider)
        }
    }

    /// Removes the key and its non-secret traces. Selection is left alone —
    /// an unconfigured selected provider falls back to Apple at engine
    /// construction time, and a manual re-selection is friendlier than
    /// yanking the picker mid-edit.
    func removeKey(for provider: TranslationProvider) {
        keys.deleteKey(for: provider.rawValue)
        hasKey[provider] = false
        keyHints[provider] = nil
        defaults.set(false, forKey: Self.hasKeyKey(provider))
        defaults.removeObject(forKey: Self.keyHintKey(provider))
        setTestResult(nil, for: provider)
    }

    // MARK: - Selection

    /// Persists the picker selection.
    func select(_ provider: TranslationProvider) {
        selectedProvider = provider
    }

    // MARK: - Connection tests

    func testResult(for provider: TranslationProvider) -> ConnectionTestResult? {
        testResults[provider]
    }

    /// Records the latest Test-button outcome (nil clears it).
    func setTestResult(_ result: ConnectionTestResult?, for provider: TranslationProvider) {
        testResults[provider] = result
        if let raw = result.map(Self.encodeTestResult) {
            defaults.set(raw, forKey: Self.testResultKey(provider))
        } else {
            defaults.removeObject(forKey: Self.testResultKey(provider))
        }
    }

    // MARK: - "Currently using" row

    /// Truthful description of the engine currently in use, including the
    /// Apple-fallback latch ("DeepL (Free) — fallback active"). Driven by
    /// published state (`fallbackActive`), never re-derived from the picker.
    func activeEngineDescription(fallbackActive: Bool) -> String {
        var label: String
        switch selectedProvider {
        case .apple:
            label = "Apple (on-device)"
        case .google:
            label = "Google Translate"
        case .deepl:
            label = deeplIsFreeTier ? "DeepL (Free)" : "DeepL (Pro)"
        case .openrouter:
            label = openRouterModel.isEmpty ? "OpenRouter" : "OpenRouter · \(openRouterModel)"
        }
        if fallbackActive, selectedProvider.isExternal {
            label += " — fallback active"
        }
        return label
    }

    // MARK: - Test-result persistence (non-secret)

    private static func encodeTestResult(_ result: ConnectionTestResult) -> String {
        switch result {
        case .success: "success"
        case let .failure(message): "failure:\(message)"
        }
    }

    private static func decodeTestResult(_ raw: String) -> ConnectionTestResult? {
        if raw == "success" {
            return .success
        }
        if raw.hasPrefix("failure:") {
            return .failure(String(raw.dropFirst("failure:".count)))
        }
        return nil
    }
}

#if DEBUG
    /// Dev-only `SecureKeyStoring` that never touches the Keychain: saves are
    /// discarded and reads always return nil, so dev builds pin translation to
    /// the Apple on-device engine and no Keychain access prompt ever fires.
    private struct DevNoopKeyStore: SecureKeyStoring {
        func saveKey(_ key: String, for providerID: String) {}

        func readKey(for providerID: String) -> String? {
            nil
        }

        func deleteKey(for providerID: String) {}
    }
#endif
