import Foundation
@testable import Mimi

/// Installs the repo's prepared JMDict database into the Application Support
/// destination `DictionaryStore` promotes into, once, when it is missing.
///
/// The test host's working directory is not the repo root, so the store's
/// debug-checkout fallback never resolves in tests — without this install,
/// any code path taking `ensureDictionaryReady`'s real default closures
/// (the session-flow suite's `start()`) would attempt a bundled-decompress
/// of an app-bundle resource the test build does not ship and fail the
/// start. nil when the repo artifact is unavailable — consumers disable
/// themselves.
///
/// The install is the same promote the store performs (plain copy into the
/// default destination), so the app's real library directory only ever
/// gains the exact file a first launch would produce.
enum InstalledJMDict {
    static let url: URL? = {
        let destination = DictionaryStore.defaultJMDictURL
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let built = repoRoot.appendingPathComponent("build/\(JMDictPin.preparedFileName)")
        guard FileManager.default.fileExists(atPath: built.path) else { return nil }
        do {
            try FileManager.default.copyItem(at: built, to: destination)
        } catch {
            return nil
        }
        return destination
    }()
}
