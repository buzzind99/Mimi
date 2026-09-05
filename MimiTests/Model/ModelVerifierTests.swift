import Foundation
@testable import Mimi
import Testing

/// Tests `ModelVerifier` against its pinned SHA-256. Mismatch/missing-file
/// verdicts run on tiny arbitrary files; the cache-hit and size-invalidation
/// paths need a digest-matching file and therefore clone the repo's dev GGUF
/// (skipped via `.enabled(if:)` when the fixture is absent — see
/// `ModelTestFixtures`). Verdict caching uses injected `VerdictStore`s at
/// temporary URLs so tests never touch the real Application Support store.
@Suite("ModelVerifier")
struct ModelVerifierTests {

    private let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory(prefix: "mimi-verify")
    }

    /// A fresh verdict store at a temporary URL (never the shared one).
    private func makeStore(_ name: String = "verdicts.json") -> ModelVerifier.VerdictStore {
        ModelVerifier.VerdictStore(url: temporary.fileURL(name))
    }

    // MARK: - isVerified

    @Test("a missing file is not verified")
    func missingFileIsUnverified() {
        let url = temporary.fileURL("missing-\(UUID().uuidString).gguf")

        #expect(!ModelVerifier.isVerified(url, for: .lite, store: makeStore()))
    }

    @Test("verify on a missing file reports a read failure with the cause")
    func verifyMissingFileThrowsReadFailure() throws {
        let url = temporary.fileURL("missing-verify-\(UUID().uuidString).gguf")

        let error = #expect(throws: ModelVerifier.VerificationError.self) {
            try ModelVerifier.verify(url, for: .lite)
        }

        #expect(try #require(error).message.contains("could not be read"))
    }

    @Test("a file that mismatches the pinned digest is not verified")
    func mismatchedDigestIsUnverified() throws {
        let file = try temporary.write(Data([0x00, 0x01, 0x02]), named: "mismatch.gguf")

        #expect(!ModelVerifier.isVerified(file, for: .lite, store: makeStore()))
        #expect(!ModelVerifier.isVerified(file, for: .lite, store: makeStore()))
    }

    @Test("a mismatching file records no persisted verdict")
    func mismatchRecordsNoVerdict() throws {
        let file = try temporary.write(Data([0x00, 0x01, 0x02]), named: "mismatch-persist.gguf")
        let store = makeStore()

        #expect(!ModelVerifier.isVerified(file, for: .lite, store: store))

        // Only positive verdicts are recorded: the store file is never created.
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test("each choice pins its own digest")
    func perChoicePins() {
        #expect(
            ModelVerifier.expectedSHA256(for: .lite) == ASRModelChoice.lite.pinnedSHA256
        )
        #expect(
            ModelVerifier.expectedSHA256(for: .full) == ASRModelChoice.full.pinnedSHA256
        )
        #expect(
            ModelVerifier.expectedSHA256(for: .lite) != ModelVerifier.expectedSHA256(for: .full)
        )
        #expect(ASRModelChoice.full.pinnedSHA256.count == 64)
    }

    /// A same-size content mutation bumps the file's mtime, so the (path,
    /// size, mtime) key no longer matches the recorded verdict and a re-hash
    /// runs — which now catches the corruption the old size-only key missed.
    @Test(
        "a size or mtime change invalidates the verdict and forces a re-hash",
        .enabled(if: TestEnvironment.repoDevModelInstalled)
    )
    func sizeOrMtimeChangeForcesRehash() throws {
        let file = try #require(try ModelTestFixtures.cloneRepoModel())
        let store = makeStore()
        #expect(
            ModelVerifier.isVerified(file, for: .lite, store: store),
            "first call hashes and caches the verdict"
        )

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data([0x5A])) // mutate content, same size — mtime changes

        #expect(
            !ModelVerifier.isVerified(file, for: .lite, store: store),
            "same-size mutation changes the mtime, forcing a re-hash"
        )
    }

    /// A persisted verdict must be trusted by a fresh store (simulated
    /// relaunch) without a re-hash. Observable because the content is
    /// corrupted before the relaunch: a re-hash would mismatch, so `true`
    /// can only come from the persisted record.
    @Test(
        "a persisted verdict survives a relaunch without re-hashing",
        .enabled(if: TestEnvironment.repoDevModelInstalled)
    )
    func persistedVerdictSurvivesRelaunch() throws {
        let file = try #require(try ModelTestFixtures.cloneRepoModel())
        let store = makeStore()
        #expect(ModelVerifier.isVerified(file, for: .lite, store: store), "first launch hashes and records")

        let recordedMtime = try #require(
            try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        )
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data([0x5A])) // corrupt content, same size
        try handle.close()
        // Restore the recorded mtime so the persisted key still matches —
        // the documented residual risk of a `cp -p` replacement.
        try FileManager.default.setAttributes([.modificationDate: recordedMtime], ofItemAtPath: file.path)

        let relaunched = ModelVerifier.VerdictStore(url: store.url)
        #expect(
            ModelVerifier.isVerified(file, for: .lite, store: relaunched),
            "fresh store (relaunch) trusts the persisted verdict"
        )
    }

    // MARK: - VerdictStore

    /// Store-tier tests run on tiny arbitrary files — recording and matching
    /// need no digest, so no fixture is required.
    @Test("record makes the key visible in a fresh store instance on the same URL")
    func recordedVerdictSurvivesFreshInstance() throws {
        let file = temporary.fileURL("model.gguf")
        try Data([0x01]).write(to: file)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let key = try ModelVerifier.CacheKey(
            path: file.path,
            size: #require(attrs[.size] as? Int64),
            modified: #require(attrs[.modificationDate] as? Date)
        )
        let store = makeStore()
        #expect(!store.contains(key), "nothing recorded yet")

        store.record(key)

        #expect(
            ModelVerifier.VerdictStore(url: store.url).contains(key),
            "a fresh instance on the same URL loads the persisted record"
        )
    }

    @Test("a mtime or size change invalidates the persisted key")
    func persistedKeyInvalidatedByAttributeChange() throws {
        let file = temporary.fileURL("model.gguf")
        try Data([0x01]).write(to: file)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let key = try ModelVerifier.CacheKey(
            path: file.path,
            size: #require(attrs[.size] as? Int64),
            modified: #require(attrs[.modificationDate] as? Date)
        )

        let store = makeStore()
        store.record(key)

        #expect(!store.contains(ModelVerifier.CacheKey(
            path: key.path, size: key.size + 1, modified: key.modified
        )), "size change invalidates")
        #expect(!store.contains(ModelVerifier.CacheKey(
            path: key.path, size: key.size, modified: key.modified.addingTimeInterval(0.001)
        )), "mtime change invalidates")
    }

    @Test("a corrupt store file degrades to empty")
    func corruptStoreDegradesToEmpty() throws {
        let storeURL = temporary.fileURL("corrupt-verdicts.json")
        try Data("not json".utf8).write(to: storeURL)

        let store = ModelVerifier.VerdictStore(url: storeURL)
        let key = ModelVerifier.CacheKey(path: "/any", size: 1, modified: Date())

        #expect(!store.contains(key), "corrupt store reads as empty, not a crash")
        // The store stays usable: recording after a corrupt load persists.
        store.record(key)
        #expect(ModelVerifier.VerdictStore(url: storeURL).contains(key))
    }

    @Test("cache keys round-trip through microsecond-rounded dates")
    func cacheKeyDateRoundingIsStable() {
        // Sub-microsecond precision must not survive the round-trip: two
        // keys differing only below the microsecond must compare equal.
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000.123_456)
        let rounded = Date(timeIntervalSinceReferenceDate: 700_000_000.123_456_4)

        #expect(
            ModelVerifier.CacheKey(path: "/m", size: 1, modified: base)
                == ModelVerifier.CacheKey(path: "/m", size: 1, modified: rounded)
        )
    }

    // MARK: - verify

    @Test("verify rejects a mismatching file with the pinned message")
    func verifyRejectsMismatch() throws {
        let file = try temporary.write(Data([0xFF]), named: "mismatch-verify.gguf")

        let error = #expect(throws: ModelVerifier.VerificationError.self) {
            try ModelVerifier.verify(file, for: .lite)
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

        try ModelVerifier.verify(file, for: .lite)
    }
}
