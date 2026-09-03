import Foundation
@testable import Mimi
import Testing

/// Tests `OpenRouterEngine` against a scripted transport: request shape,
/// lenient single-sentence parsing (fences/quotes stripped), error mapping,
/// and retry behavior (`badResponse` from a rambling reply is retried). The
/// engine's ladder mirrors production (`retriesBadResponse: true`). No network.
@Suite("OpenRouterEngine")
struct OpenRouterEngineTests {

    // MARK: - Helpers

    /// Records every request the engine issues; responses come from a
    /// scripted per-request handler (indexed by request order).
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        private(set) var bodies: [Data] = []

        let handler: @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse)

        init(handler: @escaping @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse)) {
            self.handler = handler
        }

        func record(_ request: URLRequest, body: Data?) {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            bodies.append(body ?? Data())
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.count
        }
    }

    /// Locked progress log for the `onRetry` hook.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var entries: [RetryProgress] = []

        func append(_ progress: RetryProgress) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(progress)
        }
    }

    private struct FakeResponse: Encodable {
        let choices: [FakeChoice]
    }

    private struct FakeChoice: Encodable {
        let message: FakeMessage
    }

    private struct FakeMessage: Encodable {
        let content: String
    }

    private static func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: OpenRouterEngine.endpoint, statusCode: status,
            httpVersion: nil, headerFields: nil
        )!
    }

    private static func okContent(_ content: String) -> @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse) {
        { _ in try (JSONEncoder().encode(FakeResponse(choices: [FakeChoice(message: FakeMessage(content: content))])), httpResponse(200)) }
    }

    private static func status(_ code: Int) -> @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse) {
        { _ in (Data(), httpResponse(code)) }
    }

    private func makeEngine(
        script: Script,
        apiKey: String = "openrouter-key-1234",
        model: String = "tencent/hy-mt2-30b-a3b"
    ) -> OpenRouterEngine {
        let transport = HTTPTranslationTransport(timeout: 1) { request in
            let index = script.requestCount
            script.record(request, body: request.httpBody)
            return try script.handler(index)
        }
        return OpenRouterEngine(
            apiKey: apiKey,
            model: model,
            transport: transport,
            ladder: TransientRetryLadder(retriesBadResponse: true, sleep: { _ in })
        )
    }

    private struct RequestBody: Decodable {
        let model: String
        let messages: [ChatCompletionsClient.Message]
    }

    // MARK: - Request shape

    @Test("sends one chat-completions POST per sentence with the bearer key and model verbatim")
    func requestShape() async throws {
        let script = Script(handler: Self.okContent("hello"))
        let engine = makeEngine(script: script)

        _ = try await engine.translate(["こんにちは"])

        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == OpenRouterEngine.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openrouter-key-1234")
        let body = try #require(script.bodies.first)
        let decoded = try JSONDecoder().decode(RequestBody.self, from: body)
        #expect(decoded.model == "tencent/hy-mt2-30b-a3b")
        #expect(decoded.messages.count == 2)
        #expect(decoded.messages[0].role == "system")
        // The system prompt must keep the ASR caveat — the queue only ever
        // feeds speech-recognized text, and the model needs the leniency.
        #expect(decoded.messages[0].content.contains("ASR"))
        #expect(decoded.messages[1].role == "user")
        #expect(decoded.messages[1].content == "こんにちは")
    }

    @Test("an empty model string falls back to the default model")
    func emptyModelFallsBackToDefault() async throws {
        let script = Script(handler: Self.okContent("hello"))
        let engine = makeEngine(script: script, model: "")

        _ = try await engine.translate(["こんにちは"])

        let body = try #require(script.bodies.first)
        let decoded = try JSONDecoder().decode(RequestBody.self, from: body)
        #expect(decoded.model == OpenRouterEngine.defaultModel)
    }

    @Test("multiple texts issue one request per sentence, order preserved")
    func multiTextIssuesOneRequestPerSentence() async throws {
        let script = Script(handler: { index in
            try Self.okContent("translation \(index)")(index)
        })
        let engine = makeEngine(script: script)

        let translations = try await engine.translate(["一", "二", "三"])

        #expect(translations == ["translation 0", "translation 1", "translation 2"])
        #expect(script.requestCount == 3)
    }

    // MARK: - Response parsing

    @Test("the reply is the translation")
    func happyPath() async throws {
        let script = Script(handler: Self.okContent("hello there"))
        let engine = makeEngine(script: script)

        let translations = try await engine.translate(["こんにちは"])

        #expect(translations == ["hello there"])
    }

    @Test("code fences around the translation are stripped")
    func codeFencesStripped() throws {
        #expect(try OpenRouterEngine.parse("```json\nhello\n```") == "hello")
        #expect(try OpenRouterEngine.parse("```\nhello there\n```") == "hello there")
    }

    @Test("a fence with no newline still strips the bare markers")
    func fenceWithoutNewlineStripped() throws {
        #expect(try OpenRouterEngine.parse("```hello```") == "hello")
        #expect(try OpenRouterEngine.parse("```not json") == "not json")
    }

    @Test("one pair of wrapping quotes is stripped")
    func wrappingQuotesStripped() throws {
        #expect(try OpenRouterEngine.parse("\"hello\"") == "hello")
        #expect(try OpenRouterEngine.parse("\u{201C}hello\u{201D}") == "hello")
        #expect(try OpenRouterEngine.parse("\u{300C}hello\u{300D}") == "hello")
    }

    @Test("an unquoted reply is left untouched")
    func plainReplyUnchanged() throws {
        #expect(try OpenRouterEngine.parse("hello there") == "hello there")
    }

    @Test("a whitespace-only reply surfaces as badResponse")
    func emptyTranslationThrows() {
        #expect(throws: TranslationEngineError.badResponse("Model returned an empty translation")) {
            try OpenRouterEngine.parse("   ")
        }
        #expect(throws: TranslationEngineError.badResponse("Model returned an empty translation")) {
            try OpenRouterEngine.parse("")
        }
    }

    @Test("a 200 response with no choices is retried then surfaces as badResponse")
    func noChoicesThrows() async {
        let script = Script(handler: { _ in
            try (JSONEncoder().encode(FakeResponse(choices: [])), Self.httpResponse(200))
        })
        let engine = makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .badResponse("Response contained no choices"))
        #expect(script.requestCount == 3)
    }

    @Test("an unparseable 200 body is retried then surfaces as badResponse")
    func unparseableBodyThrows() async {
        let script = Script(handler: { _ in (Data("garbage".utf8), Self.httpResponse(200)) })
        let engine = makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .badResponse("Unparseable response body"))
        #expect(script.requestCount == 3)
    }

    @Test("malformed model output is retried as badResponse")
    func malformedOutputIsRetried() async {
        // Whitespace-only replies are the lenient parse's only failure mode;
        // a rambling model gets its retry budget before the sentence fails.
        let script = Script(handler: Self.okContent("   "))
        let log = ProgressLog()
        var engine = makeEngine(script: script)
        engine.onRetry = { log.append($0) }

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .badResponse("Model returned an empty translation"))
        #expect(script.requestCount == 3)
        #expect(log.entries.map(\.attemptsLeft) == [2, 1])
    }

    // MARK: - Retry behavior

    @Test("a transient failure is retried")
    func transientFailureIsRetried() async throws {
        let script = Script(handler: { index in
            if index == 0 {
                return try Self.status(429)(index)
            }
            return try Self.okContent("hello")(index)
        })
        let log = ProgressLog()
        var engine = makeEngine(script: script)
        engine.onRetry = { log.append($0) }

        let translations = try await engine.translate(["こんにちは"])

        #expect(translations == ["hello"])
        #expect(script.requestCount == 2)
        #expect(log.entries.count == 1)
        #expect(log.entries[0].stage == .batchRetry)
        #expect(log.entries[0].attemptsLeft == 2)
    }

    @Test("an invalid key fails immediately without retrying")
    func invalidKeyFailsImmediately() async {
        let script = Script(handler: Self.status(401))
        let engine = makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .invalidKey)
        #expect(script.requestCount == 1)
    }

    // MARK: - Error mapping

    @Test("HTTP errors map into the engine taxonomy", arguments: [
        (401, TranslationEngineError.invalidKey),
        (402, TranslationEngineError.quotaExceeded),
        (429, TranslationEngineError.rateLimited),
        (500, TranslationEngineError.serverError(500))
    ])
    func errorMapping(status: Int, expected: TranslationEngineError) async {
        let script = Script(handler: Self.status(status))
        let engine = makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == expected)
    }
}
