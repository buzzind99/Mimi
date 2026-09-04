import Foundation
@testable import Mimi

/// An `ASRModelSettings` pinned to a fresh `UserDefaults` suite, with Lite
/// selected (the production default). The default `ASRModelSettings()` reads
/// the test host's `UserDefaults.standard`, where a manual app run's
/// persisted selection leaks into tests — isolate every `AppModel` through
/// this fixture. The suite name is unique per call, so parallel tests never
/// share persisted state; callers pass a `test.<Scope>` prefix so stray
/// suites remain attributable in `~/Library/Preferences`.
@MainActor
func isolatedASRModelSettings(suite: String) -> ASRModelSettings {
    let defaults = UserDefaults(suiteName: "\(suite).\(UUID().uuidString)")!
    return ASRModelSettings(defaults: defaults)
}
