import Foundation
@testable import Mimi
import Testing

/// Tests `GoogleTranslateEngine` against a scripted transport: request shape,
/// response parsing, error mapping, and HTML-entity unescaping. No network.
@Suite("GoogleTranslateEngine")
struct GoogleTranslateEngineTests {

    // MARK: - Helpers

    /// Captures the single request the engine issues and replies with a
    /// scripted response.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var request: URLRequest?
        private(set) var body: Data?

        let response: @Sendable () throws -> (Data, HTTPURLResponse)

        init(response: @escaping @Sendable () throws -> (Data, HTTPURLResponse)) {
            self.response = response
        }

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            self.request = request
            body = request.httpBody
        }
    }

    private static func ok(_ json: String) -> @Sendable () throws -> (Data, HTTPURLResponse) {
        {
            (
                Data(json.utf8),
                HTTPURLResponse(
                    url: GoogleTranslateEngine.endpoint, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
            )
        }
    }

    private func makeEngine(script: Script) -> GoogleTranslateEngine {
        let transport = HTTPTranslationTransport(timeout: 1) { request in
            script.record(request)
            return try script.response()
        }
        return GoogleTranslateEngine(
            apiKey: "google-key-1234",
            transport: transport,
            ladder: TransientRetryLadder(sleep: { _ in })
        )
    }

    private struct RequestBody: Decodable {
        let q: [String]
        let format: String
        let source: String
        let target: String
    }

    // MARK: - Request shape

    @Test("sends a POST batch request with the key in the header")
    func requestShape() async throws {
        let script = Script(response: Self.ok(#"{"data":{"translations":[{"translatedText":"hello"}]}}"#))
        let engine = makeEngine(script: script)

        _ = try await engine.translate(["こんにちは"])

        let request = try #require(script.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url == GoogleTranslateEngine.endpoint)
        #expect(request.value(forHTTPHeaderField: "X-goog-api-key") == "google-key-1234")
        let body = try #require(script.body)
        let decoded = try JSONDecoder().decode(RequestBody.self, from: body)
        #expect(decoded.q == ["こんにちは"])
        #expect(decoded.format == "text")
        #expect(decoded.source == "ja")
        #expect(decoded.target == "en")
    }

    // MARK: - Response parsing

    @Test("maps translations 1:1 and unescapes HTML entities")
    func happyPathDecodesAndUnescapes() async throws {
        let script = Script(response: Self.ok(
            #"{"data":{"translations":[{"translatedText":"it&#39;s &lt;b&gt;fine&quot;"}]}}"#
        ))
        let engine = makeEngine(script: script)

        let translations = try await engine.translate(["こんにちは"])

        #expect(translations == ["it's <b>fine\""])
    }

    @Test("a count mismatch surfaces as badResponse")
    func countMismatchThrows() async {
        let script = Script(response: Self.ok(#"{"data":{"translations":[]}}"#))
        let engine = makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == .badResponse("Expected 1 translations, got 0"))
    }

    // MARK: - Error mapping

    @Test("HTTP errors map into the engine taxonomy", arguments: [
        (400, TranslationEngineError.invalidKey),
        (403, TranslationEngineError.invalidKey),
        (429, TranslationEngineError.rateLimited),
        (500, TranslationEngineError.serverError(500))
    ])
    func errorMapping(status: Int, expected: TranslationEngineError) async {
        let script = Script(response: {
            (
                Data(),
                HTTPURLResponse(
                    url: GoogleTranslateEngine.endpoint, statusCode: status,
                    httpVersion: nil, headerFields: nil
                )!
            )
        })
        let engine = makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは"])
        }

        #expect(thrown == expected)
    }

    // MARK: - HTML entities

    @Test("decodes named, decimal, and hex entities with &amp; last")
    func entityDecoding() {
        #expect(GoogleTranslateEngine.decodingHTMLEntities("a&amp;b") == "a&b")
        #expect(GoogleTranslateEngine.decodingHTMLEntities("&#39;") == "'")
        #expect(GoogleTranslateEngine.decodingHTMLEntities("&#x27;") == "'")
        #expect(GoogleTranslateEngine.decodingHTMLEntities("&lt;x&gt;") == "<x>")
        #expect(GoogleTranslateEngine.decodingHTMLEntities("&quot;q&quot;") == "\"q\"")
        #expect(GoogleTranslateEngine.decodingHTMLEntities("&amp;#39;") == "&#39;")
        #expect(GoogleTranslateEngine.decodingHTMLEntities("plain text") == "plain text")
    }

    @Test("malformed numeric entities are left untouched")
    func malformedEntitiesUntouched() {
        #expect(GoogleTranslateEngine.decodingHTMLEntities("&#xD800;") == "&#xD800;")
        #expect(GoogleTranslateEngine.decodingHTMLEntities("&#zz;") == "&#zz;")
    }
}
