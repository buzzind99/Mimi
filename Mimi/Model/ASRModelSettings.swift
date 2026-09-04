import Foundation
import Observation

/// Non-secret ASR model selection: which `ASRModelChoice` the app resolves,
/// downloads, and runs. Persisted to UserDefaults (`"asr.model"`, raw value)
/// and defaulted to `.lite` so a fresh install never needs the full model.
/// Mirrors `TranslationSettings`' pattern: @Observable, @MainActor,
/// injectable `UserDefaults` for tests.
@Observable
@MainActor
final class ASRModelSettings {
    private(set) var selected: ASRModelChoice {
        didSet { defaults.set(selected.rawValue, forKey: Self.selectedKey) }
    }

    private let defaults: UserDefaults

    private static let selectedKey = "asr.model"

    /// - Parameter defaults: injectable for tests (unique suite per test).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.string(forKey: Self.selectedKey)
            .flatMap(ASRModelChoice.init(rawValue:)) ?? .lite
    }

    /// Persists the selection. Callers gate on availability (downloaded +
    /// verified) and the session phase before invoking this.
    func select(_ choice: ASRModelChoice) {
        selected = choice
    }
}
