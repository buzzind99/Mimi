import Foundation
@testable import Mimi
import Testing

/// Tests `OpenRouterEngine` against a scripted transport: request shape,
/// strict-JSON-array parsing (with code fences), error mapping, and batch
/// retry behavior (no per-sentence fallback). No network.
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
            ladder: TransientRetryLadder(sleep: { _ in })
        )
    }

    private struct RequestBody: Decodable {
        let model: String
        let messages: [ChatCompletionsClient.Message]
    }

    // MARK: - Request shape

    @Test("sends a chat-completions POST with the bearer key and model verbatim")
    func requestShape() async throws {
        let script = Script(handler: Self.okContent("[\"hello\"]"))
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
        #expect(decoded.messages[1].content.contains("こんにちは"))
    }

    @Test("an empty model string falls back to the default model")
    func emptyModelFallsBackToDefault() async throws {
        let script = Script(handler: Self.okContent("[\"hello\"]"))
        let engine = makeEngine(script: script, model: "")

        _ = try await engine.translate(["こんにちは"])

        let body = try #require(script.bodies.first)
        let decoded = try JSONDecoder().decode(RequestBody.self, from: body)
        #expect(decoded.model == OpenRouterEngine.defaultModel)
    }

    // MARK: - Response parsing

    @Test("parses a well-formed JSON array response 1:1")
    func happyPath() async throws {
        let script = Script(handler: Self.okContent("[\"hello\", \"world\"]"))
        let engine = makeEngine(script: script)

        let translations = try await engine.translate(["こんにちは", "世界"])

        #expect(translations == ["hello", "world"])
    }

    @Test("code fences around the JSON array are stripped")
    func codeFencesStripped() throws {
        let parsed = try OpenRouterEngine.parse("```json\n[\"hello\"]\n```", expectedCount: 1)

        #expect(parsed == ["hello"])
    }

    @Test("malformed model output surfaces as badResponse", arguments: [
        "not json at all",
        "[\"one\", \"two\", \"three\"]",
        "[\"\"]",
        "{\"translations\":[]}"
    ])
    func malformedOutputThrows(content: String) async {
        let script = Script(handler: Self.okContent(content))
        let engine = makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは", "世界"])
        }

        guard case .badResponse = thrown else {
            Issue.record("expected badResponse, got \(String(describing: thrown))")
            return
        }
    }

    // MARK: - Batch behavior

    @Test("a malformed batch fails without splitting into per-sentence requests")
    func batchFailureDoesNotSplit() async {
        // The batch returns a count mismatch; the engine surfaces the error
        // immediately instead of issuing per-sentence fallback requests.
        let script = Script(handler: Self.okContent("[\"hello\"]"))
        let log = ProgressLog()
        var engine = makeEngine(script: script)
        engine.onRetry = { log.append($0) }

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["一", "二", "三"])
        }

        #expect(thrown == .badResponse("Expected 3 translations, got 1"))
        #expect(script.requestCount == 1)
        #expect(log.entries.isEmpty)
    }

    @Test("a transient batch failure is retried")
    func transientBatchFailureIsRetried() async throws {
        let script = Script(handler: { index in
            if index == 0 {
                return try Self.status(429)(index)
            }
            if index == 1 {
                return try Self.okContent("[\"hello\"]")(index)
            }
            Issue.record("unexpected extra request")
            return try Self.okContent("[]")(index)
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
