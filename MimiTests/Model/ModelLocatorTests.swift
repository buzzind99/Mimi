import Foundation
@testable import Mimi
import Testing

/// Tests `ModelLocator` path composition and `resolve()`'s bundled →
/// downloaded → dev ordering — the order pinned over injected candidates, so
/// no real model location is touched. The end-to-end check against the real
/// downloaded model is environment-gated; the dev fallback (`models/`
/// relative to the working directory, DEBUG-only) and `resolve()`'s final
/// `nil` return sit behind the downloaded-model branch in production and are
/// unreachable in the test host whenever an installed model exists.
@Suite("ModelLocator")
struct ModelLocatorTests {

    // MARK: - Path composition

    @Test("modelsDirectory composes the Application Support path")
    func modelsDirectoryPath() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        #expect(ModelLocator.modelsDirectory == base.appendingPathComponent("Mimi/models", isDirectory: true))
        #expect(ModelLocator.modelsDirectory.lastPathComponent == "models")
    }

    @Test("downloadedURL composes the model file name inside the models directory")
    func downloadedURLPath() {
        #expect(ModelLocator.downloadedURL == ModelLocator.modelsDirectory.appendingPathComponent(ModelLocator.modelName))
        #expect(ModelLocator.downloadedURL.lastPathComponent == ModelLocator.modelName)
    }

    @Test("downloadURL points at the HuggingFace model file")
    func downloadURLPointsAtHuggingFace() {
        #expect(
            ModelDownloader.downloadURL.absoluteString ==
                "https://huggingface.co/cstr/\(ModelLocator.modelID)/resolve/main/\(ModelLocator.modelName)"
        )
    }

    // MARK: - bundledURL

    /// The app bundle ships no model resource; bundling is a packaging concern.
    @Test("bundledURL is nil when the test host bundle ships no model")
    func bundledURLNilInTestHost() {
        #expect(ModelLocator.bundledURL == nil)
    }

    // MARK: - resolve (real environment)

    @Test(
        "resolve returns the downloaded model when it is verified",
        .enabled(if: ModelVerifier.isVerified(ModelLocator.downloadedURL))
    )
    func resolveReturnsVerifiedDownloaded() {
        #expect(ModelLocator.resolve() == ModelLocator.downloadedURL)
    }

    // MARK: - resolve (injected candidates)

    @Test("a verified bundled model wins over a verified download")
    func verifiedBundledWins() {
        let bundled = URL(fileURLWithPath: "/tmp/mimi-bundled.gguf")

        let resolved = ModelLocator.resolve(
            bundled: bundled,
            downloaded: URL(fileURLWithPath: "/tmp/mimi-downloaded.gguf"),
            dev: { nil },
            fileExists: { _ in true },
            isVerified: { $0 == bundled }
        )

        #expect(resolved == bundled)
    }

    @Test("an unverified bundled model falls through to a verified download")
    func unverifiedBundledFallsThroughToDownloaded() {
        let bundled = URL(fileURLWithPath: "/tmp/mimi-bundled.gguf")
        let downloaded = URL(fileURLWithPath: "/tmp/mimi-downloaded.gguf")

        let resolved = ModelLocator.resolve(
            bundled: bundled,
            downloaded: downloaded,
            dev: { nil },
            fileExists: { _ in true },
            isVerified: { $0 == downloaded }
        )

        #expect(resolved == downloaded)
    }

    @Test("an unverified download falls through to a verified dev checkout model")
    func unverifiedDownloadedFallsThroughToDev() {
        let dev = URL(fileURLWithPath: "/tmp/mimi-dev/models/model.gguf")

        let resolved = ModelLocator.resolve(
            bundled: nil,
            downloaded: URL(fileURLWithPath: "/tmp/mimi-downloaded.gguf"),
            dev: { dev },
            fileExists: { _ in true },
            isVerified: { $0 == dev }
        )

        #expect(resolved == dev.absoluteURL)
    }

    @Test("resolve is nil when no candidate exists or verifies")
    func nothingResolves() {
        let resolved = ModelLocator.resolve(
            bundled: URL(fileURLWithPath: "/tmp/mimi-bundled.gguf"),
            downloaded: URL(fileURLWithPath: "/tmp/mimi-downloaded.gguf"),
            dev: { URL(fileURLWithPath: "/tmp/mimi-dev.gguf") },
            fileExists: { _ in false },
            isVerified: { _ in false }
        )

        #expect(resolved == nil)
    }
}
