import CryptoKit
import Foundation

/// Resolves the ASR GGUF in priority order:
///   1. Bundled: `Bundle.main` → `models/` (downloader skipped)
///   2. Downloaded: `~/Library/Application Support/Mimi/models/`
enum ModelLocator {
    static let modelName = "qwen3-asr-1.7b-ja-anime-q4_k.gguf"
    static let modelID = "qwen3-asr-1.7b-ja-anime"

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mimi/models", isDirectory: true)
    }

    /// `true` when the GGUF ships inside the app bundle.
    static var isBundled: Bool {
        bundledURL != nil
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
        if let bundled = bundledURL { return bundled }
        let downloaded = downloadedURL
        if FileManager.default.fileExists(atPath: downloaded.path) {
            return downloaded
        }
        // Development checkout: scripts/build_runtime.sh puts the dev model
        // in <repo>/models/; Xcode runs the app with that as working directory.
        let devURL = URL(fileURLWithPath: "models/\(modelName)")
        if FileManager.default.fileExists(atPath: devURL.path) {
            return devURL.absoluteURL
        }
        return nil
    }
}

/// First-launch model downloader: progress, resume, SHA-256
/// verification, retry. Also accepts a manually dropped-in GGUF (the locator
/// checks the models folder before/without any download).
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle
        case downloading(progress: Double, bytes: Int64, total: Int64?)
        case verifying
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
    private var receivedBytes: Int64 = 0
    private var expectedBytes: Int64?
    /// Pinned SHA-256 of the q4_k GGUF (release-time integrity check).
    private let expectedSHA256: String? = "da00cec556885a60d47234b4def0dbdd08394df4d4df13866d7cd9726c23ccd9"

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
            setState(.done(destination))
            return
        }

        guard session == nil else { return } // already downloading
        receivedBytes = 0
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
            self.receivedBytes = totalBytesWritten
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
        // Move synchronously: the temp file is deleted once this delegate
        // method returns.
        let destination = ModelLocator.downloadedURL
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor in
                self.task = nil
                self.state = .failed("Download failed: \(error.localizedDescription)")
            }
            return
        }
        Task { @MainActor in
            self.task = nil
            self.state = .verifying
            do {
                try self.verify(destination)
                self.resumeData = nil
                self.state = .done(destination)
            } catch {
                try? fm.removeItem(at: destination)
                self.state = .failed("Verification failed: \(error.localizedDescription)")
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

    private func verify(_ file: URL) throws {
        if let expectedSHA256 {
            let digest = try SHA256.digest(file: file)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            if hex != expectedSHA256.lowercased() {
                throw NSError(domain: "ModelDownloader", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "SHA-256 mismatch"])
            }
        } else {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path))[.size] as? Int64 ?? 0
            guard size > 10_000_000 else {
                throw NSError(domain: "ModelDownloader", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "File is too small to be the model"])
            }
        }
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
