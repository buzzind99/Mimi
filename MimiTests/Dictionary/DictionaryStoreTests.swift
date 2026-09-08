import Foundation
@testable import Mimi
import SQLite3
import Testing

// MARK: - Fake FFI shims

//
// Top-level C-convention functions (no captures, so they convert to the FFI
// function-pointer types) plus file-scope counters. The suite is serialized,
// so plain globals are safe (hence `nonisolated(unsafe)`); access is test-
// driven and never concurrent. The fake prepare actually writes a file at the
// requested output path so the store's promote step behaves like the real
// thing.

/// Placeholder payload the fake prepare leaves where the real dictionary
/// would land.
private let fakeDicContents = "fake dic"

/// The smoke word the store tokenizes; lives in the fake tokenize payloads.
private let smokeWord = "学生"

nonisolated(unsafe) var fakePrepareCalls = 0
nonisolated(unsafe) var fakePrepareDelayMs = 0
/// When set, the fake prepare copies this file (a real smoke-passing JMDict
/// database for the JMDict tests) to the output path instead of the plain
/// placeholder payload.
nonisolated(unsafe) var fakePrepareCopySource: URL?

private func fakePrepareWriteFile(
    _ zstPath: UnsafePointer<CChar>, _ outPath: UnsafePointer<CChar>
) -> Int32 {
    fakePrepareCalls += 1
    if fakePrepareDelayMs > 0 {
        usleep(useconds_t(fakePrepareDelayMs) * 1000)
    }
    let destination = URL(fileURLWithPath: String(cString: outPath))
    do {
        if let source = fakePrepareCopySource {
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            try Data(fakeDicContents.utf8).write(to: destination)
        }
        return 0
    } catch {
        return 1
    }
}

func fakePrepareFail(
    _ zstPath: UnsafePointer<CChar>, _ outPath: UnsafePointer<CChar>
) -> Int32 {
    fakePrepareCalls += 1
    return 1
}

private func fakeOpenOK(_ dicPath: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: 0xDEAD_BEEF)
}

private func fakeOpenNil(_ dicPath: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    nil
}

private func fakeTokenizeReading(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    strdup(#"[{"text":"学生","start":0,"end":2,"reading":"がくせい"}]"#)
}

private func fakeTokenizeNullReading(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    strdup(#"[{"text":"学生","start":0,"end":2,"reading":null}]"#)
}

private func fakeTokenizeNil(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    nil
}

private func fakeFreeHandle(_ handle: UnsafeMutableRawPointer?) {}

private func fakeFreeString(_ string: UnsafeMutablePointer<CChar>?) {
    guard let string else { return }
    free(string)
}

func makeFakeFFI(
    prepare: DictionaryFFI.FnPrepare = fakePrepareWriteFile,
    open: DictionaryFFI.FnOpen = fakeOpenOK,
    tokenize: DictionaryFFI.FnTokenizeJSON = fakeTokenizeReading
) -> DictionaryFFI {
    DictionaryFFI(
        open: open,
        free: fakeFreeHandle,
        tokenizeJSON: tokenize,
        freeString: fakeFreeString,
        prepare: prepare
    )
}

// MARK: - JMDict smoke database

private enum SmokeDatabaseError: Error {
    case sqlite(String)
}

/// Builds a minimal JMDict-schema SQLite database (the JMDict build's
/// tables). With `includeSmokeWord` the `学生` headword hits one entry, which
/// is exactly what the store's JMDict smoke query requires; without it the
/// database is well-formed but the smoke word misses.
func makeJMDictSmokeDatabase(includeSmokeWord: Bool = true) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimi-jmdict-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("jmdict-smoke.sqlite")

    var db: OpaquePointer?
    guard sqlite3_open_v2(
        url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
    ) == SQLITE_OK, let db else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
        sqlite3_close_v2(db)
        throw SmokeDatabaseError.sqlite(message)
    }
    defer { sqlite3_close_v2(db) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw SmokeDatabaseError.sqlite(message)
        }
    }

    try exec("""
    CREATE TABLE entries(ent_seq INTEGER PRIMARY KEY, keb TEXT, reb TEXT, common INTEGER NOT NULL);
    CREATE TABLE senses(entry_id INTEGER NOT NULL, ord INTEGER NOT NULL, pos TEXT,
      gloss TEXT NOT NULL, misc TEXT, skeb TEXT, sreb TEXT);
    CREATE TABLE headwords(entry_id INTEGER NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL,
      jlpt INTEGER, hatsuon TEXT, acc TEXT, zo TEXT);
    """)
    if includeSmokeWord {
        try exec("""
        INSERT INTO entries VALUES (1000000, '学生', 'がくせい', 1);
        INSERT INTO senses VALUES (1000000, 0, 'n', 'student', NULL, NULL, NULL);
        INSERT INTO headwords VALUES (1000000, '学生', 'keb', NULL, NULL, NULL, NULL);
        """)
    }
    return url
}

// MARK: - DictionaryStore

@Suite("DictionaryStore", .serialized)
final class DictionaryStoreTests {

    // Internal so the JMDict extension (DictionaryStoreJMDictTests.swift)
    // shares the same serialized suite state.
    let tempRoot: URL
    let destination: URL
    let fixtureZst: URL
    /// Minimal well-formed JMDict database the fake prepare can leave where
    /// the real artifact would land, so the store's JMDict smoke query passes.
    let smokeDatabase: URL

    /// Contents left at the destination to simulate a dictionary prepared by
    /// an earlier launch.
    let previousDicContents = "previously prepared"

    /// Arbitrary payload for the process-env override file (only its presence
    /// matters).
    private let overrideDicContents = "dic"

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-dictstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        destination = tempRoot.appendingPathComponent("dictionaries", isDirectory: true)
        fixtureZst = tempRoot.appendingPathComponent("system.dic.zst")
        try Data("fake zst".utf8).write(to: fixtureZst)
        smokeDatabase = try makeJMDictSmokeDatabase()
        fakePrepareCalls = 0
        fakePrepareDelayMs = 0
        fakePrepareCopySource = nil
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.removeItem(at: smokeDatabase.deletingLastPathComponent())
    }

    // MARK: Helpers

    func makeStore(
        ffi: DictionaryFFI? = makeFakeFFI(),
        bundledSource: URL? = nil,
        bundledJMDictSource: URL? = nil,
        destinationDirectory: URL? = nil
    ) -> DictionaryStore {
        DictionaryStore(
            bundledSource: bundledSource ?? fixtureZst,
            bundledJMDictSource: bundledJMDictSource ?? fixtureZst,
            destinationDirectory: destinationDirectory ?? destination,
            ffi: ffi
        )
    }

    /// Drives the store's async `prepare()` surface (the completion API
    /// underneath is exercised by every test going through this helper).
    private func prepare(_ store: DictionaryStore) async throws -> URL {
        try await store.prepare()
    }

    /// Repo root (MimiTests/Dictionary/ → repo), for the script-fetched real
    /// model.
    private var repoModelZst: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst"
        )
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: errorDescription

    @Test("explains the plain-text fallback when the library is unavailable")
    func libraryUnavailableMessage() {
        let error = DictionaryStore.DictionaryStoreError.libraryUnavailable

        #expect(
            error.errorDescription
                == "Dictionary runtime library not found; text renders unannotated."
        )
    }

    @Test("names the missing bundled asset")
    func bundledMissingMessage() {
        let error = DictionaryStore.DictionaryStoreError.bundledDictionaryMissing

        #expect(error.errorDescription == "Bundled system.dic.zst not found in the app bundle.")
    }

    @Test("includes the return code when decompression fails")
    func prepareFailedMessage() {
        let error = DictionaryStore.DictionaryStoreError.prepareFailed(returnCode: 3)

        #expect(error.errorDescription == "Dictionary decompression failed (return code 3).")
    }

    @Test("includes the reason when the smoke query fails")
    func smokeFailedMessage() {
        let error = DictionaryStore.DictionaryStoreError.smokeTestFailed(reason: "open returned null")

        #expect(error.errorDescription == "Dictionary failed its smoke query: open returned null.")
    }

    // MARK: resolve

    @Test("returns the default location when it exists")
    func resolvesDefaultLocation() {
        let dictionariesExist: (URL) -> Bool = { $0.pathComponents.contains("dictionaries") }

        let url = DictionaryStore.resolve(environment: [:], fileExists: dictionariesExist)

        #expect(url == DictionaryStore.defaultDictionaryURL)
    }

    @Test("prefers an existing env override")
    func envOverrideWins() {
        let overridePath = "/custom/ipadic.dic"
        let overrideExists: (URL) -> Bool = { $0.path == overridePath }

        let url = DictionaryStore.resolve(
            environment: ["MIMI_DICT": overridePath], fileExists: overrideExists
        )

        #expect(url?.path == overridePath)
    }

    @Test("falls through to the default location when the env override is missing")
    func missingEnvOverrideFallsThrough() {
        let missingOverride = "/missing/ipadic.dic"
        let dictionariesExist: (URL) -> Bool = { $0.pathComponents.contains("dictionaries") }

        let url = DictionaryStore.resolve(
            environment: ["MIMI_DICT": missingOverride], fileExists: dictionariesExist
        )

        #expect(url == DictionaryStore.defaultDictionaryURL)
    }

    @Test("falls back to the dev-checkout copy when only it exists")
    func devCheckoutFallback() {
        let modelsExist: (URL) -> Bool = { $0.pathComponents.contains("models") }

        let url = DictionaryStore.resolve(environment: [:], fileExists: modelsExist)

        #expect(url?.lastPathComponent == DictionaryStore.dictionaryFileName)
    }

    @Test("returns nil when nothing exists")
    func nothingResolves() {
        let nothingExists: (URL) -> Bool = { _ in false }

        let url = DictionaryStore.resolve(environment: [:], fileExists: nothingExists)

        #expect(url == nil)
    }

    #if DEBUG
        @Test("resolves the MIMI_DICT override set on the process")
        func processEnvOverride() throws {
            let overrideURL = tempRoot.appendingPathComponent("override.dic")
            try Data(overrideDicContents.utf8).write(to: overrideURL)
            dictionaryEnvLock.lock()
            defer { dictionaryEnvLock.unlock() }
            setenv("MIMI_DICT", overrideURL.path, 1)
            defer { unsetenv("MIMI_DICT") }

            let resolved = DictionaryStore.resolve()

            #expect(resolved?.path == overrideURL.path)
        }
    #endif

    // MARK: default locations

    @Test("composes the documented destination path")
    func defaultDictionaryPath() {
        let path = DictionaryStore.defaultDictionaryURL.path

        #expect(path.hasSuffix("Mimi/dictionaries/ipadic.dic"))
    }

    #if DEBUG
        @Test("falls back to the script-fetched model in debug checkouts")
        func debugBundledSourceFallback() {
            let source = DictionaryStore.defaultBundledSource

            // Debug checkouts always have a fallback (bundle or script-fetched copy).
            #expect(source != nil)
        }
    #endif

    // MARK: prepare (fake runtime — success paths)

    @Test("decompresses into place on first launch")
    func firstPrepareMovesIntoPlace() async throws {
        let store = makeStore()

        let url = try await prepare(store)

        #expect(
            url == destination.appendingPathComponent(DictionaryStore.dictionaryFileName)
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("adopts a dictionary prepared by an earlier launch without decompressing")
    func adoptsExistingDestination() async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent(DictionaryStore.dictionaryFileName)
        try Data(previousDicContents.utf8).write(to: existing)
        let store = makeStore()

        let url = try await prepare(store)

        #expect(url == existing)
        #expect(fakePrepareCalls == 0, "an existing dictionary must short-circuit the decompress")
    }

    @Test("is a no-op once prepared, even with the source gone")
    func secondPrepareIsNoOp() async throws {
        let store = makeStore()
        let prepared = try await prepare(store)
        try FileManager.default.removeItem(at: fixtureZst)

        let second = try await prepare(store)

        #expect(second == prepared, "a successful prepare must never re-decompress")
    }

    @Test("coalesces concurrent callers into one decompression")
    func concurrentCallersCoalesce() async throws {
        fakePrepareDelayMs = 300
        let store = makeStore()

        // Call `store.prepare()` directly (not via `self.prepare`) so the
        // `async let`s only send the Sendable store, not the test instance.
        async let first = store.prepare()
        async let second = store.prepare()
        async let third = store.prepare()
        let results = try await(first, second, third)

        #expect(results.0 == results.1 && results.1 == results.2)
        #expect(fakePrepareCalls == 1, "all callers must share the single decompression")
    }

    // MARK: prepare (fake runtime — failure paths)

    @Test("reports a decompression failure and leaves no partial dictionary")
    func prepareFailureLeavesNoPartialFile() async throws {
        let store = makeStore(ffi: makeFakeFFI(prepare: fakePrepareFail))

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await prepare(store)
        }

        #expect(error == .prepareFailed(returnCode: 1))
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(DictionaryStore.dictionaryFileName).path
            ),
            "a failed prepare must not leave a partial dictionary"
        )
    }

    @Test("re-attempts the decompression on the next call after a failure")
    func failedPrepareRetries() async throws {
        let store = makeStore(ffi: makeFakeFFI(prepare: fakePrepareFail))
        _ = try? await prepare(store)

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await prepare(store)
        }

        #expect(error == .prepareFailed(returnCode: 1))
        #expect(fakePrepareCalls == 2, "the retry must re-attempt the decompression")
    }

    @Test("fails the smoke query when open returns null")
    func smokeOpenFailure() async throws {
        let store = makeStore(ffi: makeFakeFFI(open: fakeOpenNil))

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await prepare(store)
        }

        #expect(error == .smokeTestFailed(reason: "open returned null"))
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(DictionaryStore.dictionaryFileName).path
            )
        )
    }

    @Test("fails the smoke query when tokenize returns null")
    func smokeTokenizeFailure() async throws {
        let store = makeStore(ffi: makeFakeFFI(tokenize: fakeTokenizeNil))

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await prepare(store)
        }

        #expect(error == .smokeTestFailed(reason: "tokenize returned null"))
    }

    @Test("fails the smoke query when the smoke word carries no reading")
    func smokeMissingReadingFailure() async throws {
        let store = makeStore(ffi: makeFakeFFI(tokenize: fakeTokenizeNullReading))

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await prepare(store)
        }

        #expect(error == .smokeTestFailed(reason: "no reading for \(smokeWord)"))
    }

    @Test("fails when the bundled model is missing")
    func bundledSourceMissing() async throws {
        let store = DictionaryStore(
            bundledSource: nil, destinationDirectory: destination, ffi: makeFakeFFI()
        )

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await prepare(store)
        }

        #expect(error == .bundledDictionaryMissing)
        #expect(fakePrepareCalls == 0)
    }

    @Test("fails when the runtime library is unavailable")
    func libraryUnavailable() async throws {
        let store = makeStore(ffi: nil)

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await prepare(store)
        }

        #expect(error == .libraryUnavailable)
    }

    // MARK: prepare (live runtime)

    @Test("decompresses the real fetched model on first launch")
    func liveFirstLaunchDecompresses() async throws {
        guard let ffi = DictionaryFFI.load(), let model = repoModelZst else {
            try Test.cancel("libdictionary.dylib or the fetched model is not available")
        }
        let store = DictionaryStore(
            bundledSource: model, destinationDirectory: destination, ffi: ffi
        )

        let started = Date()
        let url = try await prepare(store)
        let elapsed = Date().timeIntervalSince(started)

        #expect(FileManager.default.fileExists(atPath: url.path))
        print(String(format: "==> first-launch dictionary decompress wall time: %.2fs", elapsed))
    }

    @Test("is a no-op on the second live prepare, even with the source gone")
    func liveSecondPrepareIsNoOp() async throws {
        guard let ffi = DictionaryFFI.load(), let model = repoModelZst else {
            try Test.cancel("libdictionary.dylib or the fetched model is not available")
        }
        // A private copy stands in for the bundle, so it can be removed to
        // prove the second prepare never reads a source.
        let sourceCopy = tempRoot.appendingPathComponent("copied-system.dic.zst")
        try FileManager.default.copyItem(at: model, to: sourceCopy)
        let store = DictionaryStore(
            bundledSource: sourceCopy, destinationDirectory: destination, ffi: ffi
        )
        let prepared = try await prepare(store)
        try FileManager.default.removeItem(at: sourceCopy)

        let second = try await prepare(store)

        #expect(second == prepared, "a successful prepare must never re-decompress")
    }
}
