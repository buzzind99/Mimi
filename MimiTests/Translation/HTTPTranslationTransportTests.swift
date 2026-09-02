import Foundation
@testable import Mimi
import Testing

/// Tests `HTTPTranslationTransport` through the injectable `perform`
/// closure — no network, fully parallel-safe.
@Suite("HTTPTranslationTransport")
struct HTTPTranslationTransportTests {

    // MARK: - Helpers

    private static let okResponse = {
        HTTPURLResponse(url: URL(string: "https://provider.test/translate")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private func makeTransport(
        response: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    ) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 1, perform: response)
    }

    private static func response(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://provider.test/translate")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    // MARK: - Default session construction

    /// The production path (no injected `perform`) must configure a real
    /// `URLSession` without crashing; the round-trip itself needs a network
    /// and is left to integration.
    @Test("the default transport builds a real URLSession-backed sender")
    func defaultConstructionBuildsRealSession() {
        _ = HTTPTranslationTransport(timeout: 1)
    }

    // MARK: - HTTPS enforcement

    @Test("plain-HTTP requests are rejected as network errors")
    func plainHTTPRejected() async throws {
        let transport = makeTransport { _ in (Data(), Self.okResponse()) }
        var request = try URLRequest(url: #require(URL(string: "http://provider.test/translate")))
        request.httpMethod = "POST"

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await transport.send(request) { _, _ in nil }
        }

        #expect(thrown == .network)
    }

    // MARK: - Success path

    @Test("a 2xx response returns the body")
    func successReturnsBody() async throws {
        let body = Data(#"{"ok":true}"#.utf8)
        let transport = makeTransport { _ in (body, Self.okResponse()) }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        let returned = try await transport.send(request) { _, _ in nil }

        #expect(returned == body)
    }

    // MARK: - Error classification

    @Test("non-2xx responses surface the provider's classification with Retry-After")
    func non2xxClassifiedWithRetryAfter() async throws {
        let transport = makeTransport { _ in (Data(), Self.response(429, headers: ["Retry-After": "30"])) }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        let thrown = await #expect(throws: HTTPTranslationTransport.Failure.self) {
            try await transport.send(request) { _, _ in .rateLimited }
        }

        let failure = try #require(thrown)
        #expect(failure.engineError == .rateLimited)
        // Retry-After capped at 10 s even though the header said 30.
        #expect(failure.retryAfter == 10)
    }

    @Test("Retry-After passes through when under the cap")
    func retryAfterUnderCap() async throws {
        let transport = makeTransport { _ in (Data(), Self.response(429, headers: ["Retry-After": "2"])) }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        let thrown = await #expect(throws: HTTPTranslationTransport.Failure.self) {
            try await transport.send(request) { _, _ in .rateLimited }
        }

        #expect(try #require(thrown).retryAfter == 2)
    }

    @Test("Retry-After parsing failures degrade to nil")
    func retryAfterUnparseable() async throws {
        let transport = makeTransport { _ in (Data(), Self.response(429, headers: ["Retry-After": "soon"])) }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        let thrown = await #expect(throws: HTTPTranslationTransport.Failure.self) {
            try await transport.send(request) { _, _ in .rateLimited }
        }

        #expect(try #require(thrown).retryAfter == nil)
    }

    // MARK: - Transport-level failures

    @Test("generic URLSession errors map to network")
    func urlErrorMapsToNetwork() async throws {
        let transport = makeTransport { _ in
            throw URLError(.notConnectedToInternet)
        }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await transport.send(request) { _, _ in nil }
        }

        #expect(thrown == .network)
    }

    @Test("request cancellation stays CancellationError")
    func cancellationStaysCancellation() async throws {
        let transport = makeTransport { _ in
            throw URLError(.cancelled)
        }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        await #expect(throws: CancellationError.self) {
            try await transport.send(request) { _, _ in nil }
        }
    }

    @Test("a thrown CancellationError passes through unchanged")
    func thrownCancellationErrorPassesThrough() async throws {
        let transport = makeTransport { _ in
            throw CancellationError()
        }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        await #expect(throws: CancellationError.self) {
            try await transport.send(request) { _, _ in nil }
        }
    }
}
