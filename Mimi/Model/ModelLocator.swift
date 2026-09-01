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

    /// Development checkout candidate: scripts/build_runtime.sh puts the dev
    /// model in <repo>/models/; Xcode runs the app with that as working
    /// directory. Debug-only so release never depends on the cwd.
    static var devCheckoutURL: URL? {
        #if DEBUG
            return URL(fileURLWithPath: "models/\(modelName)")
        #else
            return nil
        #endif
    }

    /// Resolve the model for a session; nil means the onboarding/downloader
    /// must run first (or the user drops a GGUF in manually). Candidates,
    /// existence, and verification are injectable so tests can pin the
    /// search order without touching the real model locations; the defaults
    /// drive the bundled → downloaded → dev lookup.
    static func resolve(
        bundled: URL? = ModelLocator.bundledURL,
        downloaded: URL = ModelLocator.downloadedURL,
        dev: () -> URL? = { ModelLocator.devCheckoutURL },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isVerified: (URL) -> Bool = { ModelVerifier.isVerified($0) }
    ) -> URL? {
        if let bundled, isVerified(bundled) {
            return bundled
        }
        if fileExists(downloaded.path), isVerified(downloaded) {
            return downloaded
        }
        if let devURL = dev(), fileExists(devURL.path), isVerified(devURL) {
            return devURL.absoluteURL
        }
        return nil
    }
}
