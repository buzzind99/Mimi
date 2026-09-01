import Foundation
@testable import Mimi
@preconcurrency import Translation

/// Machine-environment availability probes shared by suites that gate tests
/// on prerequisites no test can control (native runtime, dev fixtures, OS
/// translation packs). Read-only facts about the environment, so statics are
/// safe; suites express them as `.enabled(if:)` traits or
/// `try Test.cancel("…")` so every skip is written once with a canonical
/// reason instead of each suite re-deriving the check.
enum TestEnvironment {

    /// True when `TranslationSession(installedSource:target:)` exists on this
    /// OS (macOS 26+; the deployment target is macOS 15).
    static var supportsInstalledTranslationSession: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    /// True when the OS ja→en translation pack is installed (implies
    /// `supportsInstalledTranslationSession`). Async — the availability query
    /// can consult the on-demand resources service.
    static func jaToENPackInstalled() async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        let availability = LanguageAvailability()
        return await availability.status(
            from: Locale.Language(identifier: "ja"),
            to: Locale.Language(identifier: "en")
        ) == .installed
    }

    /// True when the native ASR dylib can bind (probed once per process).
    /// Mirrors the factory: `CrispASREngine.init` binds the dylib but never
    /// touches the model file (existence is `prepare`'s job), so a
    /// nonexistent path probes dylib availability without side effects.
    static let nativeASRDylibAvailable: Bool = {
        let probe = URL(fileURLWithPath: "/tmp/mimi-dylib-probe-missing.gguf")
        return (try? CrispASREngine(modelPath: probe)) != nil
    }()

    /// True when the repo checkout's pinned-digest dev GGUF is present — the
    /// only file that can pass `ModelVerifier`'s SHA-256 pin. See
    /// `ModelTestFixtures` for cloning it into a private temp directory.
    static var repoDevModelInstalled: Bool {
        ModelTestFixtures.repoModelURL != nil
    }
}
