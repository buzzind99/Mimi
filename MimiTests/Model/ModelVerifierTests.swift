import Foundation
@testable import Mimi
import Testing

/// Tests `ModelVerifier` against its pinned SHA-256. Mismatch/missing-file
/// verdicts run on tiny arbitrary files; the cache-hit and size-invalidation
/// paths need a digest-matching file and therefore clone the repo's dev GGUF
/// (skipped via `.enabled(if:)` when the fixture is absent — see
/// `ModelTestFixtures`).
@Suite("ModelVerifier")
struct ModelVerifierTests {

    private let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory(prefix: "mimi-verify")
    }

    // MARK: - isVerified

    @Test("a missing file is not verified")
    func missingFileIsUnverified() {
        let url = temporary.fileURL("missing-\(UUID().uuidString).gguf")

        #expect(!ModelVerifier.isVerified(url))
    }

    @Test("a file that mismatches the pinned digest is not verified")
    func mismatchedDigestIsUnverified() throws {
        let file = try temporary.write(Data([0x00, 0x01, 0x02]), named: "mismatch.gguf")

        #expect(!ModelVerifier.isVerified(file))
        #expect(!ModelVerifier.isVerified(file))
    }

    /// The verdict cache only stores positives, so a cache hit is observable
    /// by mutating the file without changing its size: a re-hash would now
    /// mismatch, so a `true` verdict can only come from the cache.
    @Test(
        "a digest-matching file caches its verdict until the size changes",
        .enabled(if: TestEnvironment.repoDevModelInstalled)
    )
    func cachesVerdictUntilSizeChanges() throws {
        let file = try #require(try ModelTestFixtures.cloneRepoModel())
        #expect(ModelVerifier.isVerified(file), "first call hashes and caches the verdict")

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data([0x5A])) // mutate content, same size

        #expect(ModelVerifier.isVerified(file), "second call must skip hashing (cache hit)")

        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x5B])) // size change invalidates the cache key

        #expect(!ModelVerifier.isVerified(file), "size change forces a re-hash")
    }

    // MARK: - verify

    @Test("verify rejects a mismatching file with the pinned message")
    func verifyRejectsMismatch() throws {
        let file = try temporary.write(Data([0xFF]), named: "mismatch-verify.gguf")

        let error = #expect(throws: ModelVerifier.VerificationError.self) {
            try ModelVerifier.verify(file)
        }
        let failure = try #require(error)

        #expect(failure.message == "model file does not match Mimi's pinned checksum — "
            + "delete it and re-download, or replace it with an authentic copy")
        #expect(failure.errorDescription == failure.message)
    }

    @Test(
        "verify accepts a digest-matching file",
        .enabled(if: TestEnvironment.repoDevModelInstalled)
    )
    func verifyAcceptsMatch() throws {
        let file = try #require(try ModelTestFixtures.cloneRepoModel())

        try ModelVerifier.verify(file)
    }
}
