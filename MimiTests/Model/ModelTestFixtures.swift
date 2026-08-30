import Foundation
@testable import Mimi

/// Shared fixtures for the Model/ suites. `ModelVerifier` only accepts files
/// matching its pinned SHA-256, and no arbitrary file can be made to match —
/// but the dev checkout's `models/qwen3-asr-0.6b-q8_0.gguf` digest *is* the
/// pin. Suites that need a digest-matching input clone it (APFS copy-on-write,
/// so cloning 1 GB is free) into a private temp directory and XCTSkip when the
/// fixture is absent. Everything else runs on tiny arbitrary files.
enum ModelTestFixtures {

    /// The repo checkout's dev GGUF, whose SHA-256 equals
    /// `ModelVerifier.expectedSHA256`. `nil` when the file is absent.
    static let repoModelURL: URL? = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("models/\(ModelLocator.modelName)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    /// Clones the repo model into a fresh temp directory. Returns `nil` when
    /// the fixture is missing (callers `throw XCTSkip`).
    static func cloneRepoModel() throws -> URL? {
        guard let source = repoModelURL else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(ModelLocator.modelName)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
