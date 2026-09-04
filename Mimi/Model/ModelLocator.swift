import Foundation

/// Resolves the ASR GGUF for a chosen `ASRModelChoice` in priority order:
///   1. Bundled: `Bundle.main` → `models/` (downloader skipped)
///   2. Downloaded: `~/Library/Application Support/Mimi/models/`
///   3. Dev checkout: `<cwd>/models/` (DEBUG only)
/// Both choices live side-by-side in the shared models directory.
enum ModelLocator {
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mimi/models", isDirectory: true)
    }

    static func bundledURL(for choice: ASRModelChoice) -> URL? {
        Bundle.main.url(forResource: choice.ggufFileName, withExtension: nil, subdirectory: "models")
            ?? Bundle.main.url(forResource: choice.ggufFileName, withExtension: nil)
    }

    static func downloadedURL(for choice: ASRModelChoice) -> URL {
        modelsDirectory.appendingPathComponent(choice.ggufFileName)
    }

    /// Development checkout candidate: scripts/build_runtime.sh puts the dev
    /// model in <repo>/models/; Xcode runs the app with that as working
    /// directory. Debug-only so release never depends on the cwd.
    static func devCheckoutURL(for choice: ASRModelChoice) -> URL? {
        #if DEBUG
            return URL(fileURLWithPath: "models/\(choice.ggufFileName)")
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
        for choice: ASRModelChoice,
        bundled: (ASRModelChoice) -> URL? = { ModelLocator.bundledURL(for: $0) },
        downloaded: (ASRModelChoice) -> URL = { ModelLocator.downloadedURL(for: $0) },
        dev: (ASRModelChoice) -> URL? = { ModelLocator.devCheckoutURL(for: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isVerified: (URL, ASRModelChoice) -> Bool = { ModelVerifier.isVerified($0, for: $1) }
    ) -> URL? {
        if let bundledURL = bundled(choice), isVerified(bundledURL, choice) {
            return bundledURL
        }
        let downloadedURL = downloaded(choice)
        if fileExists(downloadedURL.path), isVerified(downloadedURL, choice) {
            return downloadedURL
        }
        if let devURL = dev(choice), fileExists(devURL.path), isVerified(devURL, choice) {
            return devURL.absoluteURL
        }
        return nil
    }
}
