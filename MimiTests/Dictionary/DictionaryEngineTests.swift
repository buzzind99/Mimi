import Darwin
import Foundation
@testable import Mimi
import Testing

// MARK: - Fixtures

private let anyText = "任意の文"

private let fakeDictionaryURL = URL(fileURLWithPath: "/tmp/fake-dictengine/ipadic.dic")

/// The runtime payload: one token with a hiragana surface reading, one
/// unknown surface without.
private let payloadMixed = #"""
[{"text":"私","start":0,"end":1,"reading":"わたし"},
 {"text":"𠮷","start":1,"end":2,"reading":null}]
"""#

private let payloadTokens = [
    DictionaryToken(text: "私", start: 0, end: 1, reading: "わたし"),
    DictionaryToken(text: "𠮷", start: 1, end: 2, reading: nil)
]

/// Serializes the process-env tests across suites: Swift Testing runs suites
/// in parallel, but `setenv`/`unsetenv` of `MIMI_DICT` is process-global.
let dictionaryEnvLock = NSLock()

// MARK: - Fake FFI shims

//
// Top-level C-convention functions (no captures, so they convert to the FFI
// function-pointer types) plus file-scope counters and a per-test payload
// variable. The suite below is serialized, so plain globals are safe.

private let fakeHandle = UnsafeMutableRawPointer(bitPattern: 0xCAFE_FEED)

private var fakeOpenCalls = 0
/// Number of initial open attempts that fail before the fake succeeds.
private var fakeOpenFailuresBeforeSuccess = 0

/// Raw JSON the tokenize fake returns; nil means "return a null pointer".
private var fakeTokenizeJSONText: String?

private var fakeFreeStringCalls = 0

private func fakeOpenCounting(_ dicPath: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    fakeOpenCalls += 1
    return fakeOpenCalls > fakeOpenFailuresBeforeSuccess ? fakeHandle : nil
}

private func fakeTokenizeWithPayload(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    guard let text = fakeTokenizeJSONText else { return nil }
    return strdup(text)
}

/// Raw byte payload with an invalid UTF-8 lead byte (0xFF), built with malloc
/// so the fake freeString's `free()` stays paired.
private func fakeTokenizeInvalidUTF8(
    _ handle: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
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

@Suite("DictionaryEngine", .serialized)
struct DictionaryEngineTests {

    init() {
        fakeOpenCalls = 0
        fakeOpenFailuresBeforeSuccess = 0
        fakeFreeStringCalls = 0
        fakeTokenizeJSONText = nil
    }

    // MARK: Helpers

    private func makeEngine(
        ffi: DictionaryFFI? = makeFakeFFI(),
        resolveDictionary: @escaping () -> URL? = { fakeDictionaryURL }
    ) -> DictionaryEngine {
        DictionaryEngine(ffi: ffi, resolveDictionary: resolveDictionary)
    }

    // MARK: fail-soft degradation

    @Test("returns nil when the runtime library is unavailable")
    func libraryUnavailable() {
        let engine = makeEngine(ffi: nil)

        #expect(engine.tokenize(anyText) == nil)
    }

    @Test("returns nil when no dictionary resolves")
    func dictionaryUnresolved() {
        let engine = makeEngine(resolveDictionary: { nil })

        #expect(engine.tokenize(anyText) == nil)
    }

    @Test("returns nil when open fails")
    func openFails() {
        let engine = makeEngine(ffi: makeFakeFFI(open: { _ in nil }))

        #expect(engine.tokenize(anyText) == nil)
    }

    @Test("returns nil when the runtime returns no payload")
    func runtimeReturnsNull() {
        let engine = makeEngine()

        #expect(engine.tokenize(anyText) == nil)
    }

    @Test("returns nil on malformed JSON")
    func malformedJSON() {
        fakeTokenizeJSONText = "not json"

        let engine = makeEngine()

        #expect(engine.tokenize(anyText) == nil)
    }

    @Test("frees the payload even when it isn't valid UTF-8")
    func invalidUTF8PayloadFreed() {
        let engine = makeEngine(ffi: makeFakeFFI(tokenize: fakeTokenizeInvalidUTF8))

        let tokens = engine.tokenize(anyText)

        #expect(tokens == nil)
        #expect(fakeFreeStringCalls == 1, "the payload must be freed even when undecodable")
    }

    @Test("frees every payload exactly once")
    func payloadFreedOnce() {
        fakeTokenizeJSONText = payloadMixed
        let engine = makeEngine()

        _ = engine.tokenize(anyText)

        #expect(fakeFreeStringCalls == 1)
    }

    // MARK: lazy open & retry

    /// The first tokenize runs while the dictionary is still unresolved (the
    /// first-launch ordering: prepare finishes, then the first annotation
    /// arrives); the act under test is the second call after it appears.
    @Test("retries the open when the dictionary resolves later")
    func dictionaryResolvedLater() {
        var dictionaryURL: URL?

        let engine = makeEngine(resolveDictionary: { dictionaryURL })

        fakeTokenizeJSONText = payloadMixed
        #expect(engine.tokenize(anyText) == nil)
        dictionaryURL = fakeDictionaryURL
        #expect(engine.tokenize(anyText) == payloadTokens)
    }

    /// The first tokenize runs against an open that fails once; the act under
    /// test is the retry, which must succeed.
    @Test("succeeds on the retry after a failed open")
    func openRetriesAfterFailure() {
        fakeOpenFailuresBeforeSuccess = 1
        fakeTokenizeJSONText = payloadMixed

        let engine = makeEngine()

        #expect(engine.tokenize(anyText) == nil)
        #expect(engine.tokenize(anyText) == payloadTokens)
    }

    /// The first tokenize opens the handle; the act under test is the second
    /// call, which must reuse the warm handle.
    @Test("keeps the handle warm across calls")
    func handleStaysWarm() {
        fakeTokenizeJSONText = payloadMixed

        let engine = makeEngine()
        _ = engine.tokenize(anyText)
        _ = engine.tokenize(anyText)

        #expect(fakeOpenCalls == 1, "the handle must stay warm across calls")
    }

    // MARK: payload decoding

    @Test("decodes surfaces, scalar spans, and readings from the payload")
    func decodesPayloadFields() throws {
        fakeTokenizeJSONText = payloadMixed
        let engine = makeEngine()

        let tokens = try #require(engine.tokenize(anyText))

        #expect(tokens == payloadTokens)
    }

    @Test("decodes an empty payload to no tokens")
    func emptyPayload() {
        fakeTokenizeJSONText = "[]"

        let engine = makeEngine()

        #expect(engine.tokenize(anyText) == [])
    }

    // MARK: default resolver wiring

    // Exercises the default `resolveDictionary` argument end-to-end: the
    // DEBUG `MIMI_DICT` env override hands `DictionaryStore.resolve()` an
    // existing file, the fake runtime opens it, and the payload decodes.
    // The env lock serializes against the store suite's own env test.
    #if DEBUG
        @Test("routes the MIMI_DICT override through the default resolver")
        func envOverrideThroughDefaultResolver() throws {
            let overrideURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mimi-dictengine-override-\(UUID().uuidString)")
            try Data("dic".utf8).write(to: overrideURL)
            defer { try? FileManager.default.removeItem(at: overrideURL) }
            dictionaryEnvLock.lock()
            defer { dictionaryEnvLock.unlock() }
            setenv("MIMI_DICT", overrideURL.path, 1)
            defer { unsetenv("MIMI_DICT") }
            fakeTokenizeJSONText = payloadMixed

            let engine = DictionaryEngine(ffi: makeFakeFFI())

            #expect(engine.tokenize(anyText) == payloadTokens)
        }
    #endif
}

// MARK: - DictionaryEngine (live runtime)

/// The live runtime shared by the live suite: the store's prepared dictionary
/// when one resolves (first launch or `MIMI_DICT`), else the script-fetched
/// model decompressed once into a private temp file. nil when the dylib or a
/// dictionary is unavailable — the suite disables itself.
private enum LiveRuntime {
    static let engine: DictionaryEngine? = {
        guard let ffi = DictionaryFFI.load() else { return nil }
        if let resolved = DictionaryStore.resolve() {
            return DictionaryEngine(ffi: ffi, resolveDictionary: { resolved })
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = repoRoot.appendingPathComponent(
            "local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst"
        )
        guard FileManager.default.fileExists(atPath: model.path) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-dictengine-live.ipadic.dic")
        guard ffi.prepare(model.path, destination.path) == 0 else { return nil }
        return DictionaryEngine(ffi: ffi, resolveDictionary: { destination })
    }()

    static var isAvailable: Bool {
        engine != nil
    }
}

/// Exercises the real `libdictionary.dylib` against the real IPADIC model.
/// Gate B lives here: vibrato performs no normalization, so every span must
/// index the original input's Unicode scalars by construction — the
/// adversarial tests pin it.
@Suite("DictionaryEngine live runtime", .enabled(if: LiveRuntime.isAvailable))
struct DictionaryEngineLiveTests {

    // MARK: Helpers

    /// Slices the token's scalar span — the only correct way to map
    /// `start`/`end` back to text.
    private func scalarSlice(
        _ token: DictionaryToken, of scalars: [Unicode.Scalar]
    ) -> String {
        String(String.UnicodeScalarView(scalars[token.start ..< token.end]))
    }

    // MARK: smoke

    @Test("tokenizes the student sentence into four surfaces")
    func studentSentenceSurfaces() throws {
        let engine = try #require(LiveRuntime.engine)

        let tokens = try #require(engine.tokenize("私は学生です"))

        #expect(tokens.map(\.text) == ["私", "は", "学生", "です"])
    }

    @Test("carries hiragana readings per surface")
    func studentSentenceReadings() throws {
        let engine = try #require(LiveRuntime.engine)

        let tokens = try #require(engine.tokenize("私は学生です"))

        #expect(tokens.map(\.reading) == ["わたし", "は", "がくせい", "です"])
    }

    @Test("carries surface readings for conjugated tokens (食べました)")
    func conjugatedSurfaceReadings() throws {
        let engine = try #require(LiveRuntime.engine)

        let tokens = try #require(engine.tokenize("食べました"))

        #expect(
            tokens.map { [$0.text, $0.reading] }
                == [["食べ", "たべ"], ["まし", "まし"], ["た", "た"]]
        )
    }

    @Test("emits counters as token pairs for the Swift fusion pass (一回)")
    func counterTokenPair() throws {
        let engine = try #require(LiveRuntime.engine)

        let tokens = try #require(engine.tokenize("一回"))

        #expect(tokens.map { [$0.text, $0.reading] } == [["一", "いち"], ["回", "かい"]])
    }

    @Test("spans the rare ideograph as one original-input scalar, unread")
    func rareIdeographSpanAndNullReading() throws {
        let engine = try #require(LiveRuntime.engine)

        let tokens = try #require(engine.tokenize("𠮷"))

        #expect(tokens == [DictionaryToken(text: "𠮷", start: 0, end: 1, reading: nil)])
    }

    @Test("leaves the space uncovered between tokens (A B)")
    func whitespaceGapUncovered() throws {
        let engine = try #require(LiveRuntime.engine)

        let tokens = try #require(engine.tokenize("A B"))

        #expect(
            tokens == [
                DictionaryToken(text: "A", start: 0, end: 1, reading: nil),
                DictionaryToken(text: "B", start: 2, end: 3, reading: nil)
            ]
        )
    }

    // MARK: Gate B — span semantics

    /// Multibyte hazards the span contract must survive: non-BMP ideographs,
    /// emoji, NFC-composing sequences (か + combining dakuten), ZWNJ, and
    /// halfwidth forms. No normalization may shift an index.
    @Test("spans index original-input scalars across multibyte hazards", arguments: [
        "私は学生です",
        "😊いいね",
        "𠮷野家",
        "か\u{3099}",
        "文\u{200C}字",
        "ﾊﾛｰ",
        "123",
        "２０２６年",
        "cafe\u{0301}"
    ])
    func spansIndexOriginalScalars(input: String) throws {
        let engine = try #require(LiveRuntime.engine)

        let tokens = try #require(engine.tokenize(input))
        let scalars = Array(input.unicodeScalars)
        var cursor = 0
        for token in tokens {
            #expect(token.start >= cursor, "tokens must be ordered and non-overlapping")
            #expect(token.end <= scalars.count, "spans must stay inside the input")
            #expect(
                scalarSlice(token, of: scalars) == token.text,
                "each span must slice back to the token's own surface"
            )
            cursor = token.end
        }
    }

    // MARK: payload lifetime

    /// Repeated heavy tokenizations must not corrupt state or degrade: every
    /// call must return tokens, and the process footprint must stay flat —
    /// payload strings are freed on every call (proven per-path by the
    /// fake-runtime pairing tests above).
    @Test("keeps memory flat across a thousand heavy tokenizations")
    func repeatedTokenizationKeepsMemoryFlat() throws {
        let heavySentence = "今日はいい天気ですね。動画を見ます。学校へ行く"
        let leakIterations = 1000
        let engine = try #require(LiveRuntime.engine)

        for _ in 0 ..< 100 {
            _ = engine.tokenize(heavySentence)
        }
        let before = physFootprint()

        for _ in 0 ..< leakIterations {
            #expect(engine.tokenize(heavySentence) != nil)
        }

        let growth = physFootprint() - before
        #expect(
            growth < 512 * 1024,
            "footprint grew \(growth)B over \(leakIterations) calls; payloads must be freed"
        )
    }
}

/// The resident footprint the OS charges this process (what Memory reports).
private func physFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}
