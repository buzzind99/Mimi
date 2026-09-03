import Foundation
import Observation

/// First-launch model downloader: progress, resume, SHA-256
/// verification, retry. Also accepts a manually dropped-in GGUF (the locator
/// checks the models folder before/without any download).
///
/// Main-actor isolated: all state mutation happens on the main actor. The
/// URLSession delegate entry points are `nonisolated` (the session invokes
/// them on its delegate queue) and hop via `Task { @MainActor in }` — the
/// protocol itself carries Sendable checking in the current SDK, so the
/// isolation must be explicit.
@Observable
@MainActor
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle
        case downloading(progress: Double, bytes: Int64, total: Int64?)
        case done(URL)
        case failed(String)
    }

    /// Mutated only on the main actor (delegate callbacks hop via Task).
    private(set) var state: State = .idle

    private func setState(_ new: State) {
        Task { @MainActor in self.state = new }
    }

    nonisolated static let downloadURL = URL(string:
        "https://huggingface.co/cstr/\(ModelLocator.modelID)/resolve/main/\(ModelLocator.modelName)")!

    private let destination: URL
    private let makeSession: (URLSessionDownloadDelegate) -> URLSession
    private let makeTask: (URLSession) -> URLSessionDownloadTask?

    /// Transport seams for tests: the destination and the session/task
    /// factories default to the real model location and URL session; tests
    /// inject a temp destination and a no-op or suspended transport so
    /// `begin()`'s file arms run without network.
    init(
        destination: URL = ModelLocator.downloadedURL,
        makeSession: @escaping (URLSessionDownloadDelegate) -> URLSession = {
            URLSession(configuration: .default, delegate: $0, delegateQueue: nil)
        },
        makeTask: @escaping (URLSession) -> URLSessionDownloadTask? = {
            $0.downloadTask(with: ModelDownloader.downloadURL)
        }
    ) {
        self.destination = destination
        self.makeSession = makeSession
        self.makeTask = makeTask
    }

    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var resumeData: Data?
    private var expectedBytes: Int64?

    /// Progress-publish throttle (main-actor confined): republish only on a
    /// ≥0.5% progress delta or ≥100 ms since the last publish — the delegate
    /// fires many times per second for a 200 MB download. Terminal states
    /// (`setState`) always publish.
    private static let progressDeltaThreshold = 0.005
    private static let progressIntervalThreshold: TimeInterval = 0.1
    private var lastPublishedProgress: Double = -1
    private var lastPublishDate: Date?

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

        if fm.fileExists(atPath: destination.path) {
            if ModelVerifier.isVerified(destination) {
                setState(.done(destination))
                return
            }
            // Corrupt or replaced file at the model destination: remove and
            // re-download (never trust an unverifiable GGUF).
            try? fm.removeItem(at: destination)
        }

        guard session == nil else { return } // already downloading
        lastPublishedProgress = -1
        lastPublishDate = nil
        setState(.downloading(progress: 0, bytes: 0, total: expectedBytes))
        let session = makeSession(self)
        self.session = session
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = makeTask(session)
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
        guard let task else { return } // idle/terminal: nothing in flight
        self.task = nil
        task.cancel(byProducingResumeData: { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                self.resumeData = data
                self.invalidateSession()
            }
        })
        setState(.idle)
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
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
            let now = Date()
            let enoughDelta = progress - lastPublishedProgress >= Self.progressDeltaThreshold
            let enoughTime =
                lastPublishDate.map { now.timeIntervalSince($0) >= Self.progressIntervalThreshold }
                    ?? true
            guard enoughDelta || enoughTime else { return }
            lastPublishedProgress = progress
            lastPublishDate = now
            self.state = .downloading(
                progress: progress, bytes: totalBytesWritten,
                total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file is deleted once this delegate method returns, so both
        // verification (at the temp location — a bad file never reaches the
        // well-known model path) and the move happen synchronously here.
        // State updates hop to the main actor afterwards.
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

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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

    private nonisolated static func verify(_ file: URL) throws(ModelVerifier.VerificationError) {
        try ModelVerifier.verify(file)
    }
}
