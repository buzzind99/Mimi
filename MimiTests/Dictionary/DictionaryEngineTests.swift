@testable import Mimi
import XCTest

// MARK: - Fixtures

private let anyText = "任意の文"

private let fakeDatabaseURL = URL(fileURLWithPath: "/tmp/fake-dictengine/jmdict.db")

private let phaseZeroPayload = #"""
[{"text":"私","start":0,"end":1,
  "dictionary_entry":{"entry_id":28684,"ent_seq":"1311110",
    "kanji_readings":[{"text":"私","priority":"ichi1","info":null,
                       "match_range":[0,1],"matched":true}],
    "kana_readings":[{"text":"わたし","no_kanji":false,"priority":"ichi1",
                      "info":null,"match_range":null,"matched":false},
                     {"text":"ワタシ","no_kanji":false,"priority":null,
                      "info":"search-only kana form","match_range":null,"matched":false}],
    "senses":[{"index":0,"pos_tags":["pronoun"],
               "glosses":[{"text":"I","lang":"eng","g_type":null}],
               "info":null,"field":null,"misc":null,"dial":null}]},
  "deinflection_reasons":null}]
"""#

private let unmatchedPayload = #"""
[{"text":"𠮷","start":0,"end":1,"dictionary_entry":null,"deinflection_reasons":null}]
"""#

// MARK: - Fake FFI shims

//
// Top-level C-convention functions (no captures, so they convert to the FFI
// function-pointer types) plus file-scope counters and a per-test payload
// variable. Tests here run serially, so plain globals are safe.

private let fakeHandle = UnsafeMutableRawPointer(bitPattern: 0xCAFE_FEED)

private var fakeOpenCalls = 0
/// Number of initial open attempts that fail before the fake succeeds.
private var fakeOpenFailuresBeforeSuccess = 0

private var fakeTokenizeCalls = 0
/// Raw JSON the tokenize fake returns; nil means "return a null pointer".
private var fakeTokenizeJSONText: String?

private var fakeFreeStringCalls = 0

private func fakeOpenCounting(_ dbPath: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    fakeOpenCalls += 1
    return fakeOpenCalls > fakeOpenFailuresBeforeSuccess ? fakeHandle : nil
}

private func fakeTokenizeWithPayload(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    fakeTokenizeCalls += 1
    guard let text = fakeTokenizeJSONText else { return nil }
    return strdup(text)
}

/// Raw byte payload with an invalid UTF-8 lead byte (0xFF), built with malloc
/// so the fake freeString's `free()` stays paired.
private func fakeTokenizeInvalidUTF8(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    fakeTokenizeCalls += 1
    guard let raw = malloc(2) else { return nil }
    let pointer = raw.assumingMemoryBound(to: CChar.self)
    pointer[0] = CChar(bitPattern: 0xFF)
    pointer[1] = 0
    return pointer
}

private func fakeFreeHandle(_ handle: UnsafeMutableRawPointer?) {}

private func fakeFreeString(_ string: UnsafeMutablePointer<CChar>?) {
    guard let string else { return }
    fakeFreeStringCalls += 1
    free(string)
}

private func makeFakeFFI(
    open: DictionaryFFI.FnOpen = fakeOpenCounting,
    tokenize: DictionaryFFI.FnTokenizeJSON = fakeTokenizeWithPayload
) -> DictionaryFFI {
    DictionaryFFI(
        open: open,
        free: fakeFreeHandle,
        tokenizeJSON: tokenize,
        freeString: fakeFreeString,
        prepare: { _, _ in 1 }
    )
}

// MARK: - DictionaryEngine (fake runtime)

final class DictionaryEngineTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeOpenCalls = 0
        fakeOpenFailuresBeforeSuccess = 0
        fakeTokenizeCalls = 0
        fakeFreeStringCalls = 0
        fakeTokenizeJSONText = nil
    }

    // MARK: Helpers

    private func makeEngine(
        open: DictionaryFFI.FnOpen = fakeOpenCounting,
        tokenize: DictionaryFFI.FnTokenizeJSON = fakeTokenizeWithPayload,
        resolveDatabase: @escaping () -> URL? = { fakeDatabaseURL }
    ) -> DictionaryEngine {
        DictionaryEngine(
            ffi: makeFakeFFI(open: open, tokenize: tokenize),
            resolveDatabase: resolveDatabase
        )
    }

    // MARK: fail-soft degradation

    func test_tokenize_whenLibraryUnavailable_shouldReturnNil() {
        let engine = DictionaryEngine(ffi: nil, resolveDatabase: { fakeDatabaseURL })

        let tokens = engine.tokenize(anyText)

        XCTAssertNil(tokens)
    }

    func test_tokenize_whenDatabaseUnresolved_shouldReturnNil() {
        let engine = makeEngine(resolveDatabase: { nil })

        let tokens = engine.tokenize(anyText)

        XCTAssertNil(tokens)
    }

    func test_tokenize_whenOpenFails_shouldReturnNil() {
        let engine = makeEngine(open: { _ in nil })

        let tokens = engine.tokenize(anyText)

        XCTAssertNil(tokens)
    }

    func test_tokenize_whenRuntimeReturnsNull_shouldReturnNil() {
        let engine = makeEngine()

        let tokens = engine.tokenize(anyText)

        XCTAssertNil(tokens)
    }

    func test_tokenize_whenPayloadIsMalformedJSON_shouldReturnNil() {
        fakeTokenizeJSONText = "not json"
        let engine = makeEngine()

        let tokens = engine.tokenize(anyText)

        XCTAssertNil(tokens)
    }

    func test_tokenize_whenPayloadIsInvalidUTF8_shouldFreeTheStringAndReturnNil() {
        let engine = makeEngine(tokenize: fakeTokenizeInvalidUTF8)

        let tokens = engine.tokenize(anyText)

        XCTAssertNil(tokens)
        XCTAssertEqual(fakeFreeStringCalls, 1, "the payload must be freed even when undecodable")
    }

    func test_tokenize_whenPayloadFreed_shouldPairFreeWithEveryPayload() {
        fakeTokenizeJSONText = unmatchedPayload
        let engine = makeEngine()

        _ = engine.tokenize(anyText)

        XCTAssertEqual(fakeFreeStringCalls, 1)
    }

    // MARK: lazy open & retry

    /// Arrange = one tokenize while the database is still unresolved; the act
    /// under test is the second call after the database appears (first-launch
    /// ordering: build finishes, then the first annotation arrives).
    func test_tokenize_whenDatabaseResolvedLater_shouldOpenOnRetry() {
        var databaseURL: URL?
        let engine = makeEngine(resolveDatabase: { databaseURL })
        fakeTokenizeJSONText = unmatchedPayload
        _ = engine.tokenize(anyText)
        databaseURL = fakeDatabaseURL

        let tokens = engine.tokenize(anyText)

        XCTAssertNotNil(tokens, "a failed open must be retried, not cached")
    }

    /// Arrange = one tokenize against an open that fails once; the act under
    /// test is the retry, which must succeed.
    func test_tokenize_whenOpenFailsOnce_shouldSucceedOnRetry() {
        fakeOpenFailuresBeforeSuccess = 1
        fakeTokenizeJSONText = unmatchedPayload
        let engine = makeEngine()
        _ = engine.tokenize(anyText)

        let tokens = engine.tokenize(anyText)

        XCTAssertNotNil(tokens)
    }

    /// Arrange = one successful tokenize (opens the handle); the act under
    /// test is the second call, which must reuse the warm handle.
    func test_tokenize_whenHandleAlreadyOpen_shouldNotReopen() {
        fakeTokenizeJSONText = unmatchedPayload
        let engine = makeEngine()
        _ = engine.tokenize(anyText)

        _ = engine.tokenize(anyText)

        XCTAssertEqual(fakeOpenCalls, 1, "the handle must stay warm across calls")
    }

    // MARK: decoding the PhaseZero JSON contract

    func test_tokenize_withPhaseZeroPayloadShape_shouldDecodeTokenFields() throws {
        fakeTokenizeJSONText = phaseZeroPayload
        let engine = makeEngine()

        let tokens = engine.tokenize(anyText)
        let token = try XCTUnwrap(tokens?.first)

        XCTAssertEqual(tokens?.count, 1)
        XCTAssertEqual(token.text, "私")
        XCTAssertEqual(token.start, 0)
        XCTAssertEqual(token.end, 1)
    }

    func test_tokenize_withPhaseZeroPayloadShape_shouldDecodeReadings() throws {
        fakeTokenizeJSONText = phaseZeroPayload
        let engine = makeEngine()

        let tokens = engine.tokenize(anyText)
        let entry = try XCTUnwrap(tokens?.first?.dictionaryEntry)

        XCTAssertEqual(entry.kanjiReadings.map(\.text), ["私"])
        XCTAssertEqual(entry.kanaReadings.count, 2)
        XCTAssertEqual(entry.kanaReadings[0].text, "わたし")
        XCTAssertEqual(entry.kanaReadings[0].priority, "ichi1")
        XCTAssertNil(entry.kanaReadings[0].info)
        XCTAssertEqual(entry.kanaReadings[0].matched, false)
        XCTAssertEqual(entry.kanaReadings[1].text, "ワタシ")
        XCTAssertNil(entry.kanaReadings[1].priority)
        XCTAssertEqual(entry.kanaReadings[1].info, "search-only kana form")
    }

    func test_tokenize_whenTokenHasNoDictionaryEntry_shouldDecodeNilEntry() {
        fakeTokenizeJSONText = unmatchedPayload
        let engine = makeEngine()

        let tokens = engine.tokenize(anyText)

        XCTAssertEqual(
            tokens,
            [DictionaryToken(text: "𠮷", start: 0, end: 1, dictionaryEntry: nil)]
        )
    }

    func test_tokenize_whenRuntimeReturnsEmptyArray_shouldDecodeEmptyTokens() {
        fakeTokenizeJSONText = "[]"
        let engine = makeEngine()

        let tokens = engine.tokenize(anyText)

        XCTAssertEqual(tokens, [])
    }

    // MARK: default resolver wiring

    /// Exercises the default `resolveDatabase` argument end-to-end: the DEBUG
    /// `MIMI_DICT` env override hands `DictionaryStore.resolve()` an
    /// existing file, the fake runtime opens it, and the payload decodes.
    /// Mirrors the store tests' env-override pattern; serial execution makes
    /// the process-global setenv safe.
    func test_init_withDefaultResolver_whenEnvOverridePointsAtDictionary_shouldTokenize() throws {
        let overrideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-dictengine-override-\(UUID().uuidString)")
        try Data("db".utf8).write(to: overrideURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: overrideURL) }
        setenv("MIMI_DICT", overrideURL.path, 1)
        defer { unsetenv("MIMI_DICT") }
        fakeTokenizeJSONText = unmatchedPayload
        let engine = DictionaryEngine(ffi: makeFakeFFI())

        let tokens = engine.tokenize(anyText)

        XCTAssertEqual(
            tokens,
            [DictionaryToken(text: "𠮷", start: 0, end: 1, dictionaryEntry: nil)]
        )
    }
}

// MARK: - DictionaryEngine (live runtime)

/// Exercises the real `libdictionary.dylib` against the prepared dictionary
/// (the resolved `DictionaryStore` location — first launch or `MIMI_DICT`).
/// Skips visibly when the runtime or a prepared dictionary is absent. The
/// full adversarial span-semantics suite (Gate B) is re-pinned here once the
/// new payload lands in Phase 3.
final class DictionaryEngineLiveTests: XCTestCase {

    private let studentSentence = "私は学生です"
    private let expectedStudentSurfaces = ["私", "は", "学生", "です"]

    /// Heavy token payload for the 1000-iteration check.
    private let heavySentence = "今日はいい天気ですね。動画を見ます。学校へ行く"

    private let leakIterations = 1000

    // MARK: Live fixtures

    private func requireLiveEngine() throws -> DictionaryEngine {
        try XCTSkipIf(DictionaryFFI.load() == nil, "libdictionary.dylib is not available")
        try XCTSkipIf(
            DictionaryStore.resolve() == nil,
            "no prepared dictionary (launch the app once, or set MIMI_DICT)"
        )
        return DictionaryEngine(
            ffi: DictionaryFFI.load(),
            resolveDatabase: { DictionaryStore.resolve() }
        )
    }

    /// Slices `input` by the token's scalar span — the only correct way to
    /// map `start`/`end` back to text.
    private func scalarSlice(_ token: DictionaryToken, of input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        let start = scalars.index(scalars.startIndex, offsetBy: token.start)
        let end = scalars.index(scalars.startIndex, offsetBy: token.end)
        return String(String.UnicodeScalarView(scalars[start ..< end]))
    }

    // MARK: smoke

    func test_tokenize_withLiveRuntime_whenStudentSentence_shouldReturnExpectedSurfaces() throws {
        let engine = try requireLiveEngine()

        let tokens = try XCTUnwrap(engine.tokenize(studentSentence))

        XCTAssertEqual(tokens.map(\.text), expectedStudentSurfaces)
    }

    func test_tokenize_withLiveRuntime_whenStudentSentence_shouldSpanOriginalScalars() throws {
        let engine = try requireLiveEngine()

        let tokens = try XCTUnwrap(engine.tokenize(studentSentence))

        XCTAssertEqual(tokens.map { scalarSlice($0, of: studentSentence) }, tokens.map(\.text))
    }

    func test_tokenize_withLiveRuntime_whenRareIdeographUnmatched_shouldIndexOriginalScalars() throws {
        let input = "𠮷"
        let engine = try requireLiveEngine()

        let tokens = try XCTUnwrap(engine.tokenize(input))

        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].start, 0)
        XCTAssertEqual(tokens[0].end, 1, "𠮷 is one Unicode scalar")
        XCTAssertEqual(tokens[0].text, input)
    }

    // MARK: payload lifetime

    /// Repeated heavy tokenizations must not corrupt state or degrade: every
    /// call must return tokens. Payload strings are proven freed on every call
    /// by the fake-runtime pairing tests above.
    func test_tokenize_withLiveRuntime_whenRepeatedThousandTimes_shouldSucceedEveryCall() throws {
        let engine = try requireLiveEngine()

        for _ in 0 ..< leakIterations {
            XCTAssertNotNil(engine.tokenize(heavySentence))
        }
    }
}
