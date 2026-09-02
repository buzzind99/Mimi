import Foundation
@testable import Mimi
import Testing

/// Tests `TranslationConnectionTester` against scripted transports.
@Suite("TranslationConnectionTester")
struct TranslationConnectionTesterTests {

    private static func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func requireFailure(
        _ result: Result<Void, TranslationEngineError>
    ) -> TranslationEngineError {
        guard case let .failure(error) = result else {
            Issue.record("expected failure, got \(result)")
            return .network
        }
        return error
    }

    @Test("Apple needs no probe")
    func appleSucceeds() async {
        let result = await TranslationConnectionTester.test(provider: .apple, key: "")

        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
    }

    @Test("Google probes with a one-sentence translate")
    func googleProbe() async {
        let googleURL = GoogleTranslateEngine.endpoint
        let transport = HTTPTranslationTransport(timeout: 1) { _ in
            (
                Data(#"{"data":{"translations":[{"translatedText":"hello"}]}}"#.utf8),
                Self.httpResponse(googleURL, 200)
            )
        }

        let result = await TranslationConnectionTester.test(provider: .google, key: "k", transport: transport)

        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
    }

    @Test("an invalid Google key fails with invalidKey")
    func googleInvalidKey() async {
        let googleURL = GoogleTranslateEngine.endpoint
        let transport = HTTPTranslationTransport(timeout: 1) { _ in
            (Data(), Self.httpResponse(googleURL, 403))
        }

        let result = await TranslationConnectionTester.test(provider: .google, key: "k", transport: transport)

        #expect(Self.requireFailure(result) == .invalidKey)
    }

    @Test("DeepL probes with a one-sentence translate against the Pro endpoint")
    func deeplProbe() async {
        let deeplURL = DeepLEngine.proEndpoint
        let transport = HTTPTranslationTransport(timeout: 1) { _ in
            (
                Data(#"{"translations":[{"detected_source_language":"JA","text":"hello"}]}"#.utf8),
                Self.httpResponse(deeplURL, 200)
            )
        }

        let result = await TranslationConnectionTester.test(provider: .deepl, key: "k", transport: transport)

        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
    }

    @Test("an invalid DeepL key fails with invalidKey without retrying")
    func deeplInvalidKey() async {
        let deeplURL = DeepLEngine.proEndpoint
        let transport = HTTPTranslationTransport(timeout: 1) { _ in
            (Data(), Self.httpResponse(deeplURL, 403))
        }

        let result = await TranslationConnectionTester.test(provider: .deepl, key: "k", transport: transport)

        #expect(Self.requireFailure(result) == .invalidKey)
    }

    @Test("a DeepL probe with an empty translation fails as badResponse")
    func deeplEmptyTranslation() async {
        let deeplURL = DeepLEngine.proEndpoint
        let transport = HTTPTranslationTransport(timeout: 1) { _ in
            (Data(#"{"translations":[{"text":""}]}"#.utf8), Self.httpResponse(deeplURL, 200))
        }

        let result = await TranslationConnectionTester.test(provider: .deepl, key: "k", transport: transport)

        #expect(Self.requireFailure(result) == .badResponse("Provider returned an empty translation"))
    }

    @Test("OpenRouter probes GET /api/v1/key with the bearer key")
    func openRouterKeyProbe() async throws {
        let keyURL = try #require(URL(string: "https://openrouter.ai/api/v1/key"))
        final class Capture: @unchecked Sendable {
            var request: URLRequest?
        }
        let capture = Capture()
        let transport = HTTPTranslationTransport(timeout: 1) { request in
            capture.request = request
            return (Data(), Self.httpResponse(keyURL, 200))
        }

        let result = await TranslationConnectionTester.test(provider: .openrouter, key: "or-key", transport: transport)

        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let request = try #require(capture.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url == keyURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer or-key")
    }

    @Test("an invalid OpenRouter key fails with invalidKey")
    func openRouterInvalidKey() async throws {
        let keyURL = try #require(URL(string: "https://openrouter.ai/api/v1/key"))
        let transport = HTTPTranslationTransport(timeout: 1) { _ in
            (Data(), Self.httpResponse(keyURL, 401))
        }

        let result = await TranslationConnectionTester.test(provider: .openrouter, key: "or-key", transport: transport)

        #expect(Self.requireFailure(result) == .invalidKey)
    }
}
