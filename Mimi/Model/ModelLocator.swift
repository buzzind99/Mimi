import CryptoKit
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
           ModelVerifier.isVerified(downloaded) {
            return downloaded
        }
        // Development checkout: scripts/build_runtime.sh puts the dev model
        // in <repo>/models/; Xcode runs the app with that as working directory.
        let devURL = URL(fileURLWithPath: "models/\(modelName)")
        if FileManager.default.fileExists(atPath: devURL.path),
           ModelVerifier.isVerified(devURL) {
            return devURL.absoluteURL
        }
        return nil
    }
}

/// Pinned-digest verification for the ASR GGUF. Verdicts are cached per
/// (path, size) so the ~200 MB re-hash only runs when the file actually
/// changes (first resolve, re-download, or a dropped-in replacement).
enum ModelVerifier {
    /// Pinned SHA-256 of the q8_0 GGUF (release-time integrity check).
    static let expectedSHA256 =
        "f547589d5ca582e093b2d3312ad9ff13b609b43d413f972c0e92b823dde70a00"

    struct VerificationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct CacheKey: Hashable {
        let path: String
        let size: Int64
    }

    private static let lock = NSLock()
    private static var verified: Set<CacheKey> = []

    /// Returns true iff the file matches the pinned SHA-256.
    static func isVerified(_ file: URL) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int64
        else { return false }
        let key = CacheKey(path: file.path, size: size)
        lock.lock()
        let cached = verified.contains(key)
        lock.unlock()
        if cached { return true }
        do {
            try verify(file)
        } catch {
            return false
        }
        lock.lock()
        verified.insert(key)
        lock.unlock()
        return true
    }

    static func verify(_ file: URL) throws {
        let digest = try SHA256.digest(file: file)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if hex != expectedSHA256.lowercased() {
            throw VerificationError(
                message: "model file does not match Mimi's pinned checksum — "
                    + "delete it and re-download, or replace it with an authentic copy")
        }
    }
}

/// First-launch model downloader: progress, resume, SHA-256
/// verification, retry. Also accepts a manually dropped-in GGUF (the locator
/// checks the models folder before/without any download).
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle
        case downloading(progress: Double, bytes: Int64, total: Int64?)
        case done(URL)
        case failed(String)
    }

    /// Mutated only on the main actor (delegate callbacks hop via Task).
    @Published private(set) var state: State = .idle

    private func setState(_ new: State) {
        Task { @MainActor in self.state = new }
    }

    static let downloadURL = URL(string:
        "https://huggingface.co/cstr/\(ModelLocator.modelID)/resolve/main/\(ModelLocator.modelName)")!

    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var resumeData: Data?
    private var expectedBytes: Int64?

    func start() {
        Task { @MainActor in
            if case .done = self.state { return }
            self.begin()
        }
    }

    private func begin() {
        let fm = FileManager.default
        try? fm.createDirectory(at: ModelLocator.modelsDirectory, withIntermediateDirectories: true)
        let destination = ModelLocator.downloadedURL

        if fm.fileExists(atPath: destination.path) {
            if ModelVerifier.isVerified(destination) {
                setState(.done(destination))
                return
            }
            // Corrupt or replaced file at Mimi's own model path: remove and
            // re-download (never trust an unverifiable GGUF).
            try? fm.removeItem(at: destination)
        }

        guard session == nil else { return } // already downloading
        setState(.downloading(progress: 0, bytes: 0, total: expectedBytes))
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: Self.downloadURL)
        }
        task?.resume()
    }

    /// The session strongly retains its delegate; invalidate to break the
    /// cycle once the download reaches a terminal state.
    @MainActor
    private func invalidateSession() {
        session?.finishTasksAndInvalidate()
        session = nil
    }

    func cancel() {
        task?.cancel(byProducingResumeData: { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                self.resumeData = data
                self.invalidateSession()
            }
        })
        task = nil
        setState(.idle)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            if totalBytesExpectedToWrite > 0 { self.expectedBytes = totalBytesExpectedToWrite }
            let progress = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                : 0
            self.state = .downloading(
                progress: progress, bytes: totalBytesWritten,
                total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file is deleted once this delegate method returns, so both
        // verification (at the temp location — a bad file never reaches the
        // well-known model path) and the move happen synchronously here.
        // State updates hop to the main actor afterwards.
        let destination = ModelLocator.downloadedURL
        let fm = FileManager.default
        var failure: Error?
        do {
            try Self.verify(location)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
        Task { @MainActor in
            self.task = nil
            self.invalidateSession()
            if let failure {
                try? fm.removeItem(at: location)
                self.state = .failed("Verification failed: \(failure.localizedDescription)")
            } else {
                self.resumeData = nil
                self.state = .done(destination)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            self.task = nil
            self.invalidateSession()
            guard let error else { return } // success handled by didFinishDownloadingTo
            if (error as NSError).code == NSURLErrorCancelled { return }
            self.state = .failed(
                "Download failed: \(error.localizedDescription). Retry, or drop the GGUF into \(ModelLocator.modelsDirectory.path) manually.")
        }
    }

    private static func verify(_ file: URL) throws {
        try ModelVerifier.verify(file)
    }
}

private extension SHA256 {
    static func digest(file: URL) throws -> SHA256Digest {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
    }
}
