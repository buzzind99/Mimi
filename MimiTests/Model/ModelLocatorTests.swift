import Foundation
@testable import Mimi
import Testing

/// Tests `ModelLocator` per-choice path composition and `resolve(for:)`'s
/// bundled → downloaded → dev ordering — the order pinned over injected
/// candidates, so no real model location is touched. The end-to-end check
/// against the real downloaded model is environment-gated; the dev fallback
/// (`models/` relative to the working directory, DEBUG-only) and
/// `resolve(for:)`'s final `nil` return sit behind the downloaded-model
/// branch in production and are unreachable in the test host whenever an
/// installed model exists.
@Suite("ModelLocator")
struct ModelLocatorTests {

    // MARK: - Path composition

    @Test("modelsDirectory composes the Application Support path")
    func modelsDirectoryPath() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        #expect(ModelLocator.modelsDirectory == base.appendingPathComponent("Mimi/models", isDirectory: true))
        #expect(ModelLocator.modelsDirectory.lastPathComponent == "models")
    }

    @Test("downloadedURL composes the choice's file name inside the shared models directory")
    func downloadedURLPath() {
        for choice in ASRModelChoice.allCases {
            #expect(
                ModelLocator.downloadedURL(for: choice)
                    == ModelLocator.modelsDirectory.appendingPathComponent(choice.ggufFileName)
            )
            #expect(ModelLocator.downloadedURL(for: choice).lastPathComponent == choice.ggufFileName)
        }
    }

    @Test("the two choices resolve to distinct side-by-side files")
    func choicesAreSideBySide() {
        let lite = ModelLocator.downloadedURL(for: .lite)
        let full = ModelLocator.downloadedURL(for: .full)

        #expect(lite != full)
        #expect(lite.deletingLastPathComponent() == full.deletingLastPathComponent())
    }

    @Test("downloadURL points at the HuggingFace model file for each choice")
    func downloadURLPointsAtHuggingFace() {
        for choice in ASRModelChoice.allCases {
            #expect(
                choice.downloadURL.absoluteString ==
                    "https://huggingface.co/cstr/\(choice.modelID)/resolve/main/\(choice.ggufFileName)"
            )
            #expect(ModelDownloader.downloadURL(for: choice) == choice.downloadURL)
        }
    }

    // MARK: - bundledURL

    /// The app bundle ships no model resource; bundling is a packaging concern.
    @Test("bundledURL is nil when the test host bundle ships no model")
    func bundledURLNilInTestHost() {
        for choice in ASRModelChoice.allCases {
            #expect(ModelLocator.bundledURL(for: choice) == nil)
        }
    }

    // MARK: - resolve (real environment)

    @Test(
        "resolve returns the downloaded Lite model when it is verified",
        .enabled(if: ModelVerifier.isVerified(ModelLocator.downloadedURL(for: .lite), for: .lite))
    )
    func resolveReturnsVerifiedDownloaded() {
        #expect(ModelLocator.resolve(for: .lite) == ModelLocator.downloadedURL(for: .lite))
    }

    @Test("the default lookup over the real environment returns nil or a verified file")
    func defaultResolveIsSelfConsistent() {
        for choice in ASRModelChoice.allCases {
            let resolved = ModelLocator.resolve(for: choice)

            if let resolved {
                #expect(FileManager.default.fileExists(atPath: resolved.path))
                #expect(ModelVerifier.isVerified(resolved, for: choice))
            }
        }
    }

    // MARK: - resolve (injected candidates)

    @Test("a verified bundled model wins over a verified download")
    func verifiedBundledWins() {
        let bundled = URL(fileURLWithPath: "/tmp/mimi-bundled.gguf")

        let resolved = ModelLocator.resolve(
            for: .lite,
            bundled: { _ in bundled },
            downloaded: { _ in URL(fileURLWithPath: "/tmp/mimi-downloaded.gguf") },
            dev: { _ in nil },
            fileExists: { _ in true },
            isVerified: { url, _ in url == bundled }
        )

        #expect(resolved == bundled)
    }

    @Test("an unverified bundled model falls through to a verified download")
    func unverifiedBundledFallsThroughToDownloaded() {
        let bundled = URL(fileURLWithPath: "/tmp/mimi-bundled.gguf")
        let downloaded = URL(fileURLWithPath: "/tmp/mimi-downloaded.gguf")

        let resolved = ModelLocator.resolve(
            for: .lite,
            bundled: { _ in bundled },
            downloaded: { _ in downloaded },
            dev: { _ in nil },
            fileExists: { _ in true },
            isVerified: { url, _ in url == downloaded }
        )

        #expect(resolved == downloaded)
    }

    @Test("an unverified download falls through to a verified dev checkout model")
    func unverifiedDownloadedFallsThroughToDev() {
        let dev = URL(fileURLWithPath: "/tmp/mimi-dev/models/model.gguf")

        let resolved = ModelLocator.resolve(
            for: .lite,
            bundled: { _ in nil },
            downloaded: { _ in URL(fileURLWithPath: "/tmp/mimi-downloaded.gguf") },
            dev: { _ in dev },
            fileExists: { _ in true },
            isVerified: { url, _ in url == dev }
        )

        #expect(resolved == dev.absoluteURL)
    }

    @Test("resolve is nil when no candidate exists or verifies")
    func nothingResolves() {
        let resolved = ModelLocator.resolve(
            for: .full,
            bundled: { _ in URL(fileURLWithPath: "/tmp/mimi-bundled.gguf") },
            downloaded: { _ in URL(fileURLWithPath: "/tmp/mimi-downloaded.gguf") },
            dev: { _ in URL(fileURLWithPath: "/tmp/mimi-dev.gguf") },
            fileExists: { _ in false },
            isVerified: { _, _ in false }
        )

        #expect(resolved == nil)
    }

    @Test("resolve composes the choice's candidates per choice")
    func resolveUsesChoiceCandidates() {
        let liteURL = URL(fileURLWithPath: "/tmp/lite.gguf")
        let fullURL = URL(fileURLWithPath: "/tmp/full.gguf")

        let resolvedLite = ModelLocator.resolve(
            for: .lite,
            bundled: { _ in nil },
            downloaded: { _ in liteURL },
            dev: { _ in nil },
            fileExists: { _ in true },
            isVerified: { _, _ in true }
        )
        let resolvedFull = ModelLocator.resolve(
            for: .full,
            bundled: { _ in nil },
            downloaded: { _ in fullURL },
            dev: { _ in nil },
            fileExists: { _ in true },
            isVerified: { _, _ in true }
        )

        #expect(resolvedLite == liteURL)
        #expect(resolvedFull == fullURL)
    }

    @Test("the default candidate locators fall through to nil when nothing exists")
    func defaultClosuresFallThroughToNil() {
        let resolved = ModelLocator.resolve(for: .full, fileExists: { _ in false })

        #expect(resolved == nil)
    }

    @Test("the dev checkout points at the repo-relative models directory")
    func devCheckoutURLIsRepoRelative() {
        for choice in ASRModelChoice.allCases {
            let url = ModelLocator.devCheckoutURL(for: choice)

            #expect(url?.path.hasSuffix("models/\(choice.ggufFileName)") == true)
        }
    }
}
