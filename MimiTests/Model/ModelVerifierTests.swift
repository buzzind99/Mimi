@testable import Mimi
import XCTest

/// Tests `ModelVerifier` against its pinned SHA-256. Mismatch/missing-file
/// verdicts run on tiny arbitrary files; the cache-hit and size-invalidation
/// paths need a digest-matching file and therefore clone the repo's dev GGUF
/// (skipped when the fixture is absent — see ModelTestFixtures).
final class ModelVerifierTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempFile(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-verify-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - isVerified

    func test_isVerified_whenFileMissing_shouldReturnFalse() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-missing-\(UUID().uuidString)")

        XCTAssertFalse(ModelVerifier.isVerified(url))
    }

    func test_isVerified_whenDigestMismatches_shouldReturnFalse() throws {
        let file = try makeTempFile(bytes: [0x00, 0x01, 0x02])

        XCTAssertFalse(ModelVerifier.isVerified(file))
        XCTAssertFalse(ModelVerifier.isVerified(file))
    }

    /// The verdict cache only stores positives, so a cache hit is observable
    /// by mutating the file without changing its size: a re-hash would now
    /// mismatch, so a `true` verdict can only come from the cache.
    func test_isVerified_whenDigestMatches_shouldCacheVerdict_untilSizeChanges() throws {
        guard let file = try ModelTestFixtures.cloneRepoModel() else {
            throw XCTSkip("repo dev model (pinned-digest fixture) is not present")
        }
        XCTAssertTrue(ModelVerifier.isVerified(file), "first call hashes and caches the verdict")

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data([0x5A])) // mutate content, same size

        XCTAssertTrue(ModelVerifier.isVerified(file), "second call must skip hashing (cache hit)")

        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x5B])) // size change invalidates the cache key

        XCTAssertFalse(ModelVerifier.isVerified(file), "size change forces a re-hash")
    }

    // MARK: - verify

    func test_verify_whenDigestMismatches_shouldThrowVerificationErrorWithPinnedMessage() throws {
        let file = try makeTempFile(bytes: [0xFF])

        do {
            try ModelVerifier.verify(file)
            XCTFail("verify must reject a file that does not match the pinned digest")
        } catch let error as ModelVerifier.VerificationError {
            XCTAssertEqual(
                error.message,
                "model file does not match Mimi's pinned checksum — "
                    + "delete it and re-download, or replace it with an authentic copy"
            )
            XCTAssertEqual(error.errorDescription, error.message)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_verify_whenDigestMatches_shouldNotThrow() throws {
        guard let file = try ModelTestFixtures.cloneRepoModel() else {
            throw XCTSkip("repo dev model (pinned-digest fixture) is not present")
        }

        try ModelVerifier.verify(file)
    }
}
