import Foundation
@testable import Mimi
import Testing

/// Tests `ModelDownloader` state transitions by invoking the
/// `URLSessionDownloadDelegate` callbacks directly (no network). `begin()`'s
/// file arms run over injected transports — a temp destination plus a no-op
/// or suspended task factory, so nothing touches the network or the real
/// installed model. The live download path — the resume-data arm, a real
/// transfer in flight, and the session/task wiring against HuggingFace —
/// needs a real HuggingFace transfer and stays excluded. The
/// `didFinishDownloadingTo` success path uses a clone of the repo's dev GGUF
/// (digest matches the pin; skipped when absent). That clone is moved into
/// the installed-model location, replacing the previous file byte-for-byte.
@MainActor
@Suite("ModelDownloader")
struct ModelDownloaderTests {

    private let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory(prefix: "mimi-download")
    }

    // MARK: - Helpers

    private func makeDownloadTask() throws -> URLSessionDownloadTask {
        let url = try #require(URL(string: "https://example.invalid/mimi-test.gguf"))
        return URLSession.shared.downloadTask(with: url)
    }

    /// Lets the unstructured `Task { @MainActor }` hops spawned by the
    /// delegate callbacks run before state assertions.
    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    private func waitFor(
        _ downloader: ModelDownloader,
        timeout: TimeInterval,
        _ predicate: (ModelDownloader.State) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(downloader.state) {
                return true
            }
            await Task.yield()
        }
        return false
    }

    /// A transport whose task factory is never called: `begin()` runs its
    /// file-side effects and stops before any network work.
    private func makeOfflineTransport(destination: URL) -> ModelDownloader {
        ModelDownloader(
            destination: destination,
            makeSession: { _ in URLSession(configuration: .ephemeral) },
            makeTask: { _ in nil }
        )
    }

    // MARK: - cancel

    @Test("cancel while idle is a no-op that republishes nothing")
    func cancelWhileIdle() async {
        let downloader = ModelDownloader()
        let emissions = ObservedValuesRecorder(read: { downloader.state })

        downloader.cancel()
        downloader.cancel()
        await settle()

        #expect(downloader.state == .idle)
        #expect(emissions.values.isEmpty, "idle cancel must not republish .idle")
    }

    // MARK: - start

    @Test(
        "start finishes done for an already-verified model and ignores further starts",
        .enabled(if: ModelVerifier.isVerified(ModelLocator.downloadedURL))
    )
    func startWhenVerifiedModelAlreadyPresent() async {
        let destination = ModelLocator.downloadedURL
        let downloader = ModelDownloader()

        downloader.start()
        let done = await waitFor(downloader, timeout: 30) { state in
            if case .done = state {
                return true
            }
            return false
        }
        #expect(done, "state should reach .done via the already-verified-model arm")
        #expect(downloader.state == .done(destination))

        let emissions = ObservedValuesRecorder(read: { downloader.state })
        downloader.start()
        await settle()

        #expect(emissions.values.isEmpty, "start() once .done must be a no-op")
    }

    @Test(
        "start finishes done for a verified file at the destination",
        .enabled(if: TestEnvironment.repoDevModelInstalled)
    )
    func startWithVerifiedDestinationFinishesDone() async throws {
        let file = try #require(try ModelTestFixtures.cloneRepoModel())
        let downloader = makeOfflineTransport(destination: file)

        downloader.start()
        let done = await waitFor(downloader, timeout: 30) { state in
            if case .done = state {
                return true
            }
            return false
        }

        #expect(done, "state should reach .done via the already-verified-model arm")
        #expect(downloader.state == .done(file))
    }

    @Test("start removes an unverified file at the destination before downloading")
    func startRemovesUnverifiedDestination() async throws {
        let file = try temporary.write(Data([0x00, 0x01, 0x02]), named: ModelLocator.modelName)
        let downloader = makeOfflineTransport(destination: file)

        downloader.start()
        let downloading = await waitFor(downloader, timeout: 5) { state in
            if case .downloading = state {
                return true
            }
            return false
        }
        #expect(downloading, "state should reach .downloading after clearing the bad file")
        #expect(downloader.state == .downloading(progress: 0, bytes: 0, total: nil))
        #expect(!FileManager.default.fileExists(atPath: file.path), "an unverifiable destination is removed")

        let emissions = ObservedValuesRecorder(read: { downloader.state })
        downloader.start()
        await settle()

        #expect(emissions.values.isEmpty, "a second start while already downloading is a no-op")
    }

    @Test("cancel while a task is in flight returns to idle without a failure")
    func cancelWhileTaskInFlight() async throws {
        let url = try #require(URL(string: "https://example.invalid/mimi-test.gguf"))
        let downloader = ModelDownloader(
            destination: temporary.fileURL("in-flight.gguf"),
            makeSession: { _ in URLSession(configuration: .ephemeral) },
            makeTask: { session in
                let task = session.downloadTask(with: url)
                // Suspend twice: begin()'s resume() consumes one suspension,
                // leaving the task suspended so no network ever starts. A
                // single suspend would let the task run and race cancel()
                // against a real DNS failure for the invalid host.
                task.suspend()
                task.suspend()
                return task
            }
        )
        let emissions = ObservedValuesRecorder(read: { downloader.state })

        downloader.start()
        _ = await waitFor(downloader, timeout: 5) { state in
            if case .downloading = state {
                return true
            }
            return false
        }
        downloader.cancel()
        let idle = await waitFor(downloader, timeout: 5) { state in
            if case .idle = state {
                return true
            }
            return false
        }
        // The .idle emission is recorded via a main-actor hop; let it land
        // before reading the recorder.
        await settle()

        #expect(idle, "cancel() publishes the idle state")
        #expect(downloader.state == .idle)
        #expect(emissions.values.last == .idle)
    }

    // MARK: - didWriteData

    @Test("didWriteData publishes fractional progress for a known total")
    func didWriteDataPublishesFractionalProgress() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 250, totalBytesWritten: 250, totalBytesExpectedToWrite: 1000
        )
        await settle()

        #expect(downloader.state == .downloading(progress: 0.25, bytes: 250, total: 1000))
    }

    @Test("didWriteData publishes zero progress and nil total for an unknown total")
    func didWriteDataPublishesZeroProgressForUnknownTotal() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 100, totalBytesWritten: 300, totalBytesExpectedToWrite: 0
        )
        await settle()

        #expect(downloader.state == .downloading(progress: 0, bytes: 300, total: nil))
    }

    @Test("didWriteData throttles a sub-0.5% progress delta within the publish interval")
    func didWriteDataThrottlesSmallDeltas() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        // First callback always publishes (0.25 ≥ the delta threshold from
        // the -1 seed); the second (0.251, +0.1%) is throttled.
        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 250, totalBytesWritten: 250, totalBytesExpectedToWrite: 1000
        )
        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 1, totalBytesWritten: 251, totalBytesExpectedToWrite: 1000
        )
        await settle()

        #expect(downloader.state == .downloading(progress: 0.25, bytes: 250, total: 1000))
    }

    // MARK: - didFinishDownloadingTo

    @Test("didFinishDownloadingTo fails on a digest mismatch and removes the temp file")
    func didFinishDownloadingToDigestMismatch() async throws {
        let downloader = ModelDownloader()
        let tempFile = try temporary.write(Data([0x01, 0x02, 0x03]), named: "bad-digest.gguf")
        let task = try makeDownloadTask()
        let destination = ModelLocator.downloadedURL
        let destinationExisted = FileManager.default.fileExists(atPath: destination.path)

        downloader.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: tempFile)
        await settle()

        #expect(
            downloader.state ==
                .failed(
                    "Verification failed: model file does not match Mimi's pinned checksum — "
                        + "delete it and re-download, or replace it with an authentic copy"
                )
        )
        #expect(!FileManager.default.fileExists(atPath: tempFile.path), "temp file must be removed")
        #expect(
            FileManager.default.fileExists(atPath: destination.path) == destinationExisted,
            "a failed verification must never touch the model destination"
        )
    }

    @Test(
        "didFinishDownloadingTo moves a digest-matching file into place and finishes",
        .enabled(if: TestEnvironment.repoDevModelInstalled)
    )
    func didFinishDownloadingToDigestMatch() async throws {
        let tempFile = try #require(try ModelTestFixtures.cloneRepoModel())
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()
        let destination = ModelLocator.downloadedURL

        downloader.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: tempFile)
        let done = await waitFor(downloader, timeout: 30) { state in
            if case .done = state {
                return true
            }
            return false
        }
        #expect(done, "state should reach .done after verification and move")
        #expect(downloader.state == .done(destination))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: tempFile.path), "temp file is consumed by the move")
    }

    // MARK: - didCompleteWithError

    @Test("didCompleteWithError with a nil error stays idle")
    func didCompleteWithErrorNilStaysIdle() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(.shared, task: task, didCompleteWithError: nil)
        await settle()

        #expect(downloader.state == .idle, "success is handled by didFinishDownloadingTo")
    }

    @Test("didCompleteWithError with a cancelled error stays idle")
    func didCompleteWithErrorCancelledStaysIdle() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        downloader.urlSession(.shared, task: task, didCompleteWithError: error)
        await settle()

        #expect(downloader.state == .idle, "cancel() already published the idle state")
    }

    @Test("didCompleteWithError with a failure publishes the failed message")
    func didCompleteWithErrorPublishesFailure() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
        )

        downloader.urlSession(.shared, task: task, didCompleteWithError: error)
        await settle()

        #expect(
            downloader.state ==
                .failed(
                    "Download failed: offline. Retry, or drop the GGUF into "
                        + "\(ModelLocator.modelsDirectory.path) manually."
                )
        )
    }
}
