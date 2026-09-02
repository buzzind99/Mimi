import Foundation
@testable import Mimi
import Testing

/// Tests `DeepLEngine` against a scripted transport: tier auto-detection,
/// request shape, response parsing, and error mapping. No network.
@Suite("DeepLEngine")
struct DeepLEngineTests {

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
                    url: DeepLEngine.proEndpoint, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
            )
        }
    }

    private func makeEngine(script: Script, apiKey: String = "deepl-key-1234") -> DeepLEngine {
        let transport = HTTPTranslationTransport(timeout: 1) { request in
            script.record(request)
            return try script.response()
        }
        return DeepLEngine(
            apiKey: apiKey,
            transport: transport,
            ladder: TransientRetryLadder(sleep: { _ in })
        )
    }

    // MARK: - Tier auto-detection

    @Test("a :fx key suffix selects the free host, otherwise Pro")
    func hostAutoDetection() {
        #expect(DeepLEngine.endpoint(for: "abc123:fx") == DeepLEngine.freeEndpoint)
        #expect(DeepLEngine.endpoint(for: "abc123") == DeepLEngine.proEndpoint)
        #expect(DeepLEngine.isFreeTier("abc123:fx"))
        #expect(!DeepLEngine.isFreeTier("abc123"))
    }

    // MARK: - Request shape

    @Test("sends a POST batch request with the DeepL auth header")
    func requestShape() async throws {
        let script = Script(response: Self.ok(#"{"translations":[{"text":"hello"}]}"#))
        let engine = makeEngine(script: script)

        _ = try await engine.translate(["こんにちは"])

        let request = try #require(script.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url == DeepLEngine.proEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key deepl-key-1234")
        let body = try #require(script.body)
        let decoded = try JSONDecoder().decode(DeepLRequestBodyFixture.self, from: body)
        #expect(decoded.text == ["こんにちは"])
        #expect(decoded.sourceLang == "JA")
        #expect(decoded.targetLang == "EN")
    }

    @Test("a free-tier key targets the free host")
    func freeKeyTargetsFreeHost() async throws {
        let script = Script(response: Self.ok(#"{"translations":[{"text":"hello"}]}"#))
        let engine = makeEngine(script: script, apiKey: "abc:fx")

        _ = try await engine.translate(["こんにちは"])

        let request = try #require(script.request)
        #expect(request.url == DeepLEngine.freeEndpoint)
    }

    // MARK: - Response parsing

    @Test("maps translations 1:1")
    func happyPath() async throws {
        let script = Script(response: Self.ok(
            #"{"translations":[{"text":"hello"},{"text":"world"}]}"#
        ))
        let engine = makeEngine(script: script)

        let translations = try await engine.translate(["こんにちは", "世界"])

        #expect(translations == ["hello", "world"])
    }

    @Test("a count mismatch surfaces as badResponse")
    func countMismatchThrows() async {
        let script = Script(response: Self.ok(#"{"translations":[{"text":"hello"}]}"#))
        let engine = makeEngine(script: script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["こんにちは", "世界"])
        }

        #expect(thrown == .badResponse("Expected 2 translations, got 1"))
    }

    // MARK: - Error mapping

    @Test("HTTP errors map into the engine taxonomy", arguments: [
        (403, TranslationEngineError.invalidKey),
        (456, TranslationEngineError.quotaExceeded),
        (429, TranslationEngineError.rateLimited),
        (500, TranslationEngineError.serverError(500))
    ])
    func errorMapping(status: Int, expected: TranslationEngineError) async {
        let script = Script(response: {
            (
                Data(),
                HTTPURLResponse(
                    url: DeepLEngine.proEndpoint, statusCode: status,
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
}

private struct DeepLRequestBodyFixture: Decodable {
    let text: [String]
    let sourceLang: String
    let targetLang: String

    enum CodingKeys: String, CodingKey {
        case text
        case sourceLang = "source_lang"
        case targetLang = "target_lang"
    }
}
