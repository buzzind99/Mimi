import Foundation

/// Resolves the ASR GGUF in priority order:
///   1. Bundled: `Bundle.main` → `models/` (downloader skipped)
///   2. Downloaded: `~/Library/Application Support/Mimi/models/`
enum ModelLocator {
    static let modelName = "qwen3-asr-0.6b-q8_0.gguf"
    static let modelID = "qwen3-asr-0.6b-GGUF"

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mimi/models", isDirectory: true)
    }

    static var bundledURL: URL? {
        Bundle.main.url(forResource: modelName, withExtension: nil, subdirectory: "models")
            ?? Bundle.main.url(forResource: modelName, withExtension: nil)
    }

    static var downloadedURL: URL {
        modelsDirectory.appendingPathComponent(modelName)
    }

    /// Resolve the model for a session; nil means the onboarding/downloader
    /// must run first (or the user drops a GGUF in manually).
    static func resolve() -> URL? {
        if let bundled = bundledURL, ModelVerifier.isVerified(bundled) {
            return bundled
        }
        let downloaded = downloadedURL
        if FileManager.default.fileExists(atPath: downloaded.path),
           ModelVerifier.isVerified(downloaded)
        {
            return downloaded
        }
        // Development checkout: scripts/build_runtime.sh puts the dev model
        // in <repo>/models/; Xcode runs the app with that as working directory.
        let devURL = URL(fileURLWithPath: "models/\(modelName)")
        if FileManager.default.fileExists(atPath: devURL.path),
           ModelVerifier.isVerified(devURL)
        {
            return devURL.absoluteURL
        }
        return nil
    }
}
