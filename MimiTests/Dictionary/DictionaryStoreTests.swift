import Compression
@testable import Mimi
import XCTest

// MARK: - Fixtures

/// Builds a tiny gzip'd JMdict_e fixture in-process (raw DEFLATE via the
/// Compression framework wrapped in gzip framing), mirroring the vendored
/// Rust integration test's `MINI_JMDICT` so both languages exercise the same
/// build path.
private enum MiniJMdict {
    /// Word certain to exist in any JMdict build; lives in the fixture XML and
    /// backs the store's smoke-query expectations.
    static let smokeWord = "学生"

    static let xml = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE JMdict [
    <!ENTITY n "noun (common) (futsuumeishi)">
    <!ENTITY v1 "Ichidan verb">
    ]>
    <JMdict>
    <entry>
    <ent_seq>1549240</ent_seq>
    <k_ele><keb>学生</keb><ke_pri>ichi1</ke_pri></k_ele>
    <r_ele><reb>がくせい</reb><re_pri>ichi1</re_pri></r_ele>
    <sense><pos>&n;</pos><gloss>student</gloss></sense>
    </entry>
    <entry>
    <ent_seq>1418230</ent_seq>
    <k_ele><keb>食べる</keb><ke_pri>ichi1</ke_pri></k_ele>
    <r_ele><reb>たべる</reb><re_pri>ichi1</re_pri></r_ele>
    <sense><pos>&v1;</pos><gloss>to eat</gloss></sense>
    </entry>
    </JMdict>
    """#

    static func makeGz() throws -> Data {
        let source = Array(xml.utf8)
        var compressed = [UInt8](repeating: 0, count: source.count + 256)
        let written = compression_encode_buffer(
            &compressed, compressed.count, source, source.count, nil, COMPRESSION_ZLIB
        )
        guard written > 0 else {
            throw NSError(domain: "MiniJMdict", code: 1, userInfo: nil)
        }
        // gzip framing: 10-byte header (magic, deflate, no flags, mtime 0,
        // OS unknown), the raw DEFLATE stream, CRC32 + ISIZE little-endian.
        var data = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        data.append(contentsOf: compressed[0 ..< written])
        var crc = Self.crc32(source).littleEndian
        var isize = UInt32(truncatingIfNeeded: source.count).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &crc) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: &isize) { Data($0) })
        return data
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Fake FFI shims

//
// Top-level C-convention functions (no captures, so they convert to the FFI
// function-pointer types) plus file-scope counters. Tests here run serially,
// so plain globals are safe. The fake buildDB actually writes a file at the
// requested DB path so the store's promote step behaves like the real thing.

/// Placeholder payload the fake buildDB leaves where the real DB would land.
private let fakeDBContents = "fake db"

private var fakeBuildCalls = 0
private var fakeBuildDelayMs = 0

private func fakeBuildDBWriteFile(
    _ dbPath: UnsafePointer<CChar>, _ gzPath: UnsafePointer<CChar>
) -> Int32 {
    fakeBuildCalls += 1
    if fakeBuildDelayMs > 0 {
        usleep(useconds_t(fakeBuildDelayMs) * 1000)
    }
    let destination = URL(fileURLWithPath: String(cString: dbPath))
    do {
        try Data(fakeDBContents.utf8).write(to: destination)
        return 0
    } catch {
        return 1
    }
}

private func fakeBuildDBFail(
    _ dbPath: UnsafePointer<CChar>, _ gzPath: UnsafePointer<CChar>
) -> Int32 {
    fakeBuildCalls += 1
    return 1
}

private func fakeOpenOK(_ dbPath: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: 0xDEAD_BEEF)
}

private func fakeOpenNil(_ dbPath: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    nil
}

private func fakeTokenizeEntry(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>, _ maxResults: UInt32
) -> UnsafeMutablePointer<CChar>? {
    strdup(
        #"[{"text":"学生","start":0,"end":2,"dictionary_entry":{"ent_seq":"1549240"},"deinflection_reasons":null}]"#
    )
}

private func fakeTokenizeEmpty(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>, _ maxResults: UInt32
) -> UnsafeMutablePointer<CChar>? {
    strdup("[]")
}

private func fakeTokenizeNil(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>, _ maxResults: UInt32
) -> UnsafeMutablePointer<CChar>? {
    nil
}

private func fakeFreeHandle(_ handle: UnsafeMutableRawPointer?) {}

private func fakeLookupNil(
    _ handle: UnsafeMutableRawPointer?, _ word: UnsafePointer<CChar>, _ maxResults: UInt32
) -> UnsafeMutablePointer<CChar>? {
    nil
}

private func fakeFreeString(_ string: UnsafeMutablePointer<CChar>?) {
    guard let string else { return }
    free(string)
}

private func makeFakeFFI(
    build: DictionaryFFI.FnBuildDB = fakeBuildDBWriteFile,
    open: DictionaryFFI.FnOpen = fakeOpenOK,
    tokenize: DictionaryFFI.FnTokenizeJSON = fakeTokenizeEntry
) -> DictionaryFFI {
    DictionaryFFI(
        buildDB: build,
        open: open,
        free: fakeFreeHandle,
        tokenizeJSON: tokenize,
        lookupJSON: fakeLookupNil,
        freeString: fakeFreeString
    )
}

// MARK: - DictionaryStore

final class DictionaryStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var destination: URL!
    private var fixtureGz: URL!

    /// Contents left at the destination to simulate a DB built by an earlier
    /// launch.
    private let previousDBContents = "previously built"

    /// Arbitrary payload for the process-env override file (only its presence
    /// matters).
    private let overrideDBContents = "db"

    private func requireFFI() throws -> DictionaryFFI {
        try XCTUnwrap(DictionaryFFI.load(), "libdictionary.dylib is not available")
    }

    /// Repo root (MimiTests/Text/ → repo), for the script-fetched real gz.
    private var repoDictionaryGz: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("local/dictionaries/JMdict_e.gz")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-dictstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        destination = tempRoot.appendingPathComponent("dictionaries", isDirectory: true)
        fixtureGz = tempRoot.appendingPathComponent("JMdict_e.gz")
        try MiniJMdict.makeGz().write(to: fixtureGz)
        fakeBuildCalls = 0
        fakeBuildDelayMs = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: Helpers

    private func makeStore(ffi: DictionaryFFI? = makeFakeFFI()) -> DictionaryStore {
        DictionaryStore(
            bundledSource: fixtureGz, destinationDirectory: destination, ffi: ffi
        )
    }

    private func prepareAndWait(
        _ store: DictionaryStore, timeout: TimeInterval = 60
    ) throws -> Result<URL, Error> {
        let ready = expectation(description: "prepare")
        var result: Result<URL, Error>?
        store.prepare {
            result = $0
            ready.fulfill()
        }
        wait(for: [ready], timeout: timeout)
        return try XCTUnwrap(result, "completion must run exactly once")
    }

    // MARK: errorDescription

    func test_errorDescription_whenLibraryUnavailable_shouldExplainPlainTextFallback() {
        let error = DictionaryStore.DictionaryStoreError.libraryUnavailable

        let message = error.errorDescription

        XCTAssertEqual(
            message, "Dictionary runtime library not found; text renders unannotated."
        )
    }

    func test_errorDescription_whenBundledDictionaryMissing_shouldNameTheMissingAsset() {
        let error = DictionaryStore.DictionaryStoreError.bundledDictionaryMissing

        let message = error.errorDescription

        XCTAssertEqual(message, "Bundled JMdict_e.gz not found in the app bundle.")
    }

    func test_errorDescription_whenBuildFailed_shouldIncludeReturnCode() {
        let error = DictionaryStore.DictionaryStoreError.buildFailed(returnCode: 3)

        let message = error.errorDescription

        XCTAssertEqual(message, "Dictionary database build failed (return code 3).")
    }

    func test_errorDescription_whenSmokeTestFailed_shouldIncludeReason() {
        let error = DictionaryStore.DictionaryStoreError.smokeTestFailed(reason: "open returned null")

        let message = error.errorDescription

        XCTAssertEqual(
            message, "Dictionary database failed its smoke query: open returned null."
        )
    }

    // MARK: resolve

    func test_resolve_whenDefaultLocationExists_shouldReturnIt() {
        let dictionariesExist: (URL) -> Bool = { $0.pathComponents.contains("dictionaries") }

        let url = DictionaryStore.resolve(environment: [:], fileExists: dictionariesExist)

        XCTAssertEqual(url, DictionaryStore.defaultDatabaseURL)
    }

    func test_resolve_whenEnvOverrideExists_shouldPreferIt() {
        let overridePath = "/custom/db.sqlite"
        let overrideExists: (URL) -> Bool = { $0.path == overridePath }

        let url = DictionaryStore.resolve(
            environment: ["MIMI_JMDICT_DB": overridePath], fileExists: overrideExists
        )

        XCTAssertEqual(url?.path, overridePath)
    }

    func test_resolve_whenEnvOverrideMissing_shouldFallThroughToDefaultLocation() {
        let missingOverride = "/missing/db.sqlite"
        let dictionariesExist: (URL) -> Bool = { $0.pathComponents.contains("dictionaries") }

        let url = DictionaryStore.resolve(
            environment: ["MIMI_JMDICT_DB": missingOverride], fileExists: dictionariesExist
        )

        XCTAssertEqual(url, DictionaryStore.defaultDatabaseURL)
    }

    func test_resolve_whenOnlyDevCheckoutExists_shouldReturnIt() {
        let modelsExist: (URL) -> Bool = { $0.pathComponents.contains("models") }

        let url = DictionaryStore.resolve(environment: [:], fileExists: modelsExist)

        XCTAssertEqual(url?.lastPathComponent, DictionaryStore.databaseFileName)
    }

    func test_resolve_whenNothingExists_shouldReturnNil() {
        let nothingExists: (URL) -> Bool = { _ in false }

        let url = DictionaryStore.resolve(environment: [:], fileExists: nothingExists)

        XCTAssertNil(url)
    }

    #if DEBUG
        func test_resolve_whenEnvOverrideSetOnProcess_shouldResolveToOverride() throws {
            let overrideURL = tempRoot.appendingPathComponent("override.db")
            try Data(overrideDBContents.utf8).write(to: overrideURL)
            setenv("MIMI_JMDICT_DB", overrideURL.path, 1)
            defer { unsetenv("MIMI_JMDICT_DB") }

            let resolved = DictionaryStore.resolve()

            XCTAssertEqual(resolved?.path, overrideURL.path)
        }
    #endif

    // MARK: default locations

    func test_defaultDatabaseURL_whenComposed_shouldMatchDocumentedPath() {
        let path = DictionaryStore.defaultDatabaseURL.path

        XCTAssertTrue(path.hasSuffix("Mimi/dictionaries/jmdict.db"))
    }

    #if DEBUG
        func test_defaultBundledSource_whenDebug_shouldFallBackToScriptFetchedCopy() {
            let source = DictionaryStore.defaultBundledSource

            // Debug checkouts always have a fallback (bundle or script-fetched copy).
            XCTAssertNotNil(source)
        }
    #endif

    // MARK: prepare (real runtime)

    func test_prepare_whenTinyFixtureProvided_shouldBuildOpenableDatabase() throws {
        let store = try makeStore(ffi: requireFFI())

        let url = try prepareAndWait(store).get()

        XCTAssertEqual(url, destination.appendingPathComponent("jmdict.db"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// Arrange = one successful prepare (builds the DB); the act under test is
    /// the second call, which must be a no-op even with the source gz gone.
    func test_prepare_whenAlreadyBuilt_shouldBeNoOp() throws {
        let store = try makeStore(ffi: requireFFI())
        let built = try prepareAndWait(store).get()
        try FileManager.default.removeItem(at: fixtureGz)

        let second = try prepareAndWait(store).get()

        XCTAssertEqual(second, built, "a successful prepare must never rebuild")
    }

    func test_prepare_withRealBundledGz_shouldBuildRealDatabase() throws {
        let source = try XCTUnwrap(repoDictionaryGz, "local/dictionaries/JMdict_e.gz is not fetched")
        let store = try DictionaryStore(
            bundledSource: source, destinationDirectory: destination, ffi: requireFFI()
        )

        let started = Date()
        let url = try prepareAndWait(store, timeout: 120).get()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        print(String(format: "==> first-launch JMdict build wall time: %.2fs", elapsed))
    }

    // MARK: prepare (fake runtime — failure paths & coalescing)

    func test_prepare_whenDestinationExists_shouldAdoptWithoutBuilding() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("jmdict.db")
        try Data(previousDBContents.utf8).write(to: existing)
        let store = makeStore()

        let url = try prepareAndWait(store).get()

        XCTAssertEqual(url, existing)
        XCTAssertEqual(fakeBuildCalls, 0, "an existing DB must short-circuit the build")
    }

    func test_prepare_whenCalledConcurrently_shouldCoalesceIntoOneBuild() throws {
        fakeBuildDelayMs = 300
        let store = makeStore()
        var results: [Result<URL, Error>] = []
        let firstDone = expectation(description: "prepare 1")
        let secondDone = expectation(description: "prepare 2")
        let thirdDone = expectation(description: "prepare 3")

        store.prepare { results.append($0); firstDone.fulfill() }
        store.prepare { results.append($0); secondDone.fulfill() }
        store.prepare { results.append($0); thirdDone.fulfill() }

        wait(for: [firstDone, secondDone, thirdDone], timeout: 30)

        XCTAssertNoThrow(try results[0].get())
        XCTAssertNoThrow(try results[1].get())
        XCTAssertNoThrow(try results[2].get())
        XCTAssertEqual(fakeBuildCalls, 1, "all callers must share the single build")
    }

    func test_prepare_whenBuildFails_shouldReportErrorAndLeaveNoPartialDatabase() throws {
        let store = makeStore(ffi: makeFakeFFI(build: fakeBuildDBFail))

        let error = try prepareAndWait(store).getError()

        guard case let .buildFailed(returnCode) = error as? DictionaryStore.DictionaryStoreError
        else {
            return XCTFail("expected .buildFailed, got \(error)")
        }
        XCTAssertEqual(returnCode, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("jmdict.db").path
            ),
            "a failed build must not leave a partial database"
        )
    }

    /// Arrange = one failing prepare; the act under test is the retry, which
    /// must re-attempt the build (phase reset) instead of reporting a stale
    /// success.
    func test_prepare_whenBuildFailed_shouldRetryOnNextCall() throws {
        let store = makeStore(ffi: makeFakeFFI(build: fakeBuildDBFail))
        _ = try? prepareAndWait(store).getError()

        let error = try prepareAndWait(store).getError()

        guard case .buildFailed = error as? DictionaryStore.DictionaryStoreError else {
            return XCTFail("expected .buildFailed on retry, got \(error)")
        }
        XCTAssertEqual(fakeBuildCalls, 2, "the retry must re-attempt the build")
    }

    func test_prepare_whenSmokeOpenReturnsNull_shouldFailWithoutLeavingDatabase() throws {
        let store = makeStore(ffi: makeFakeFFI(open: fakeOpenNil))

        let error = try prepareAndWait(store).getError()

        guard case let .smokeTestFailed(reason) = error as? DictionaryStore.DictionaryStoreError
        else {
            return XCTFail("expected .smokeTestFailed, got \(error)")
        }
        XCTAssertEqual(reason, "open returned null")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("jmdict.db").path
            )
        )
    }

    func test_prepare_whenSmokeQueryFindsNoEntries_shouldFail() throws {
        let store = makeStore(ffi: makeFakeFFI(tokenize: fakeTokenizeEmpty))

        let error = try prepareAndWait(store).getError()

        guard case let .smokeTestFailed(reason) = error as? DictionaryStore.DictionaryStoreError
        else {
            return XCTFail("expected .smokeTestFailed, got \(error)")
        }
        XCTAssertEqual(reason, "no dictionary entry for \(MiniJMdict.smokeWord)")
    }

    func test_prepare_whenSmokeTokenizeReturnsNull_shouldFail() throws {
        let store = makeStore(ffi: makeFakeFFI(tokenize: fakeTokenizeNil))

        let error = try prepareAndWait(store).getError()

        guard case let .smokeTestFailed(reason) = error as? DictionaryStore.DictionaryStoreError
        else {
            return XCTFail("expected .smokeTestFailed, got \(error)")
        }
        XCTAssertEqual(reason, "tokenize returned null")
    }

    func test_prepare_whenBundledSourceMissing_shouldFail() throws {
        let store = DictionaryStore(
            bundledSource: nil, destinationDirectory: destination, ffi: makeFakeFFI()
        )

        let error = try prepareAndWait(store).getError()

        guard case .bundledDictionaryMissing = error as? DictionaryStore.DictionaryStoreError else {
            return XCTFail("expected .bundledDictionaryMissing, got \(error)")
        }
        XCTAssertEqual(fakeBuildCalls, 0)
    }

    func test_prepare_whenLibraryUnavailable_shouldFail() throws {
        let store = DictionaryStore(
            bundledSource: fixtureGz, destinationDirectory: destination, ffi: nil
        )

        let error = try prepareAndWait(store).getError()

        guard case .libraryUnavailable = error as? DictionaryStore.DictionaryStoreError else {
            return XCTFail("expected .libraryUnavailable, got \(error)")
        }
    }
}

// MARK: - Result helpers

private extension Result where Success == URL, Failure == Error {
    func getError() throws -> Error {
        switch self {
        case let .success(url):
            throw NSError(
                domain: "DictionaryStoreTests", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "unexpected success: \(url)"]
            )
        case let .failure(error):
            return error
        }
    }
}
