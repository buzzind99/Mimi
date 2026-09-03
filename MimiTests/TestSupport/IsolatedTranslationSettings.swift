import Foundation
@testable import Mimi

/// A `TranslationSettings` pinned to a fresh `UserDefaults` suite and an
/// in-memory key store, with Apple on-device selected. The default
/// `TranslationSettings()` reads the test host's `UserDefaults.standard`,
/// where a manual app run's persisted provider selection leaks into tests
/// (engine selection, error copy) — isolate every `AppModel` through this
/// fixture. The suite name is unique per call, so parallel tests never
/// share persisted state; callers pass a `test.<Scope>` prefix so stray
/// suites remain attributable in `~/Library/Preferences`.
@MainActor
func isolatedTranslationSettings(suite: String) -> TranslationSettings {
    let defaults = UserDefaults(suiteName: "\(suite).\(UUID().uuidString)")!
    let settings = TranslationSettings(defaults: defaults, keys: InMemoryKeyStore())
    settings.select(.apple)
    return settings
}
