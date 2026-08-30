import Combine
@testable import Mimi
import XCTest

/// Tests `ModelDownloader` state transitions by invoking the
/// `URLSessionDownloadDelegate` callbacks directly (no network). The live
/// download path — `begin()`'s session/task setup, the resume-data and
/// corrupt-file arms, and `cancel()` while a transfer is in flight — needs a
/// real HuggingFace transfer. The
/// `didFinishDownloadingTo` success path uses a clone of the repo's dev GGUF
/// (digest matches the pin; skipped when absent). That clone is moved into the
/// installed-model location, replacing the previous file byte-for-byte.
@MainActor
final class ModelDownloaderTests: XCTestCase {

    // MARK: - Helpers

    private func makeDownloadTask() throws -> URLSessionDownloadTask {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/mimi-test.gguf"))
        return URLSession.shared.downloadTask(with: url)
    }

    private func makeTempFile(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-download-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
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

    // MARK: - cancel

    func test_cancel_whenIdle_shouldBeTrueNoOp() async {
        let downloader = ModelDownloader()
        var emissions: [ModelDownloader.State] = []
        let subscription = downloader.$state.dropFirst().sink { emissions.append($0) }
        defer { subscription.cancel() }

        downloader.cancel()
        downloader.cancel()
        await settle()

        XCTAssertEqual(downloader.state, .idle)
        XCTAssertTrue(emissions.isEmpty, "idle cancel must not republish .idle")
    }

    // MARK: - start

    func test_start_whenVerifiedModelAlreadyPresent_shouldFinishDone_andIgnoreFurtherStarts() async throws {
        let destination = ModelLocator.downloadedURL
        guard FileManager.default.fileExists(atPath: destination.path),
              ModelVerifier.isVerified(destination)
        else {
            throw XCTSkip("no verified model at the download path; start() would run a real download")
        }
        let downloader = ModelDownloader()

        downloader.start()
        let done = await waitFor(downloader, timeout: 30) {
            if case .done = $0 {
                return true
            }; return false
        }
        XCTAssertTrue(done, "state should reach .done via the already-verified-model arm")
        XCTAssertEqual(downloader.state, .done(destination))

        var emissions: [ModelDownloader.State] = []
        let subscription = downloader.$state.dropFirst().sink { emissions.append($0) }
        defer { subscription.cancel() }
        downloader.start()
        await settle()

        XCTAssertTrue(emissions.isEmpty, "start() once .done must be a no-op")
    }

    // MARK: - didWriteData

    func test_didWriteData_withKnownTotal_shouldPublishFractionalProgress() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 250, totalBytesWritten: 250, totalBytesExpectedToWrite: 1000
        )
        await settle()

        XCTAssertEqual(downloader.state, .downloading(progress: 0.25, bytes: 250, total: 1000))
    }

    func test_didWriteData_withUnknownTotal_shouldPublishZeroProgressAndNilTotal() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 100, totalBytesWritten: 300, totalBytesExpectedToWrite: 0
        )
        await settle()

        XCTAssertEqual(downloader.state, .downloading(progress: 0, bytes: 300, total: nil))
    }

    // MARK: - didFinishDownloadingTo

    func test_didFinishDownloadingTo_whenDigestMismatches_shouldFailAndRemoveTempFile() async throws {
        let downloader = ModelDownloader()
        let tempFile = try makeTempFile(bytes: [0x01, 0x02, 0x03])
        let task = try makeDownloadTask()
        let destination = ModelLocator.downloadedURL
        let destinationExisted = FileManager.default.fileExists(atPath: destination.path)

        downloader.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: tempFile)
        await settle()

        XCTAssertEqual(
            downloader.state,
            .failed(
                "Verification failed: model file does not match Mimi's pinned checksum — "
                    + "delete it and re-download, or replace it with an authentic copy"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path), "temp file must be removed")
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: destination.path),
            destinationExisted,
            "a failed verification must never touch the model destination"
        )
    }

    func test_didFinishDownloadingTo_whenDigestMatches_shouldMoveIntoPlaceAndFinish() async throws {
        guard let tempFile = try ModelTestFixtures.cloneRepoModel() else {
            throw XCTSkip("repo dev model (pinned-digest fixture) is not present")
        }
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()
        let destination = ModelLocator.downloadedURL

        downloader.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: tempFile)
        let done = await waitFor(downloader, timeout: 30) {
            if case .done = $0 {
                return true
            }; return false
        }
        XCTAssertTrue(done, "state should reach .done after verification and move")
        XCTAssertEqual(downloader.state, .done(destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path), "temp file is consumed by the move")
    }

    // MARK: - didCompleteWithError

    func test_didCompleteWithError_withNilError_shouldStayIdle() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(.shared, task: task, didCompleteWithError: nil)
        await settle()

        XCTAssertEqual(downloader.state, .idle, "success is handled by didFinishDownloadingTo")
    }

    func test_didCompleteWithError_whenCancelled_shouldStayIdle() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        downloader.urlSession(.shared, task: task, didCompleteWithError: error)
        await settle()

        XCTAssertEqual(downloader.state, .idle, "cancel() already published the idle state")
    }

    func test_didCompleteWithError_whenFailure_shouldPublishFailedMessage() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
        )

        downloader.urlSession(.shared, task: task, didCompleteWithError: error)
        await settle()

        XCTAssertEqual(
            downloader.state,
            .failed(
                "Download failed: offline. Retry, or drop the GGUF into "
                    + "\(ModelLocator.modelsDirectory.path) manually."
            )
        )
    }
}
