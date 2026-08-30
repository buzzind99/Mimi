@testable import Mimi
import XCTest

/// Tests `ModelLocator` path composition and `resolve()`'s bundled/downloaded
/// ordering. The dev fallback (`models/` relative to the working directory,
/// DEBUG-only) and `resolve()`'s final `nil` return sit behind the
/// downloaded-model branch and are unreachable in the test host whenever an
/// installed model exists
final class ModelLocatorTests: XCTestCase {

    // MARK: - Path composition

    func test_modelsDirectory_shouldComposeApplicationSupportPath() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        XCTAssertEqual(
            ModelLocator.modelsDirectory,
            base.appendingPathComponent("Mimi/models", isDirectory: true)
        )
        XCTAssertEqual(ModelLocator.modelsDirectory.lastPathComponent, "models")
    }

    func test_downloadedURL_shouldComposeModelFileNameInsideModelsDirectory() {
        XCTAssertEqual(
            ModelLocator.downloadedURL,
            ModelLocator.modelsDirectory.appendingPathComponent(ModelLocator.modelName)
        )
        XCTAssertEqual(ModelLocator.downloadedURL.lastPathComponent, ModelLocator.modelName)
    }

    func test_downloadURL_shouldPointAtHuggingFaceModelFile() {
        XCTAssertEqual(
            ModelDownloader.downloadURL.absoluteString,
            "https://huggingface.co/cstr/\(ModelLocator.modelID)/resolve/main/\(ModelLocator.modelName)"
        )
    }

    // MARK: - bundledURL

    func test_bundledURL_whenTestHostBundleHasNoModel_shouldReturnNil() {
        // The app bundle ships no model resource; bundling is a packaging concern.
        XCTAssertNil(ModelLocator.bundledURL)
    }

    // MARK: - resolve

    func test_resolve_whenDownloadedModelVerified_shouldReturnDownloadedURL() throws {
        let downloaded = ModelLocator.downloadedURL
        guard FileManager.default.fileExists(atPath: downloaded.path) else {
            throw XCTSkip("no downloaded model in this environment")
        }
        guard ModelVerifier.isVerified(downloaded) else {
            throw XCTSkip("downloaded model does not match the pinned digest")
        }

        XCTAssertEqual(ModelLocator.resolve(), downloaded)
    }
}
