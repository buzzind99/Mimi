import Combine
import Foundation

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
            if case .done = self.state {
                return
            }
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
            if totalBytesExpectedToWrite > 0 {
                self.expectedBytes = totalBytesExpectedToWrite
            }
            let progress = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                : 0
            self.state = .downloading(
                progress: progress, bytes: totalBytesWritten,
                total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            )
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
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }
            self.state = .failed(
                "Download failed: \(error.localizedDescription). Retry, or drop the GGUF into \(ModelLocator.modelsDirectory.path) manually."
            )
        }
    }

    private static func verify(_ file: URL) throws {
        try ModelVerifier.verify(file)
    }
}
