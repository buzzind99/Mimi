import Foundation

/// Batch-translation REST client core, factored so Google v2 and DeepL v2 are
/// thin config variants (the same shape `ChatCompletionsClient` provides for
/// chat-completions APIs): each engine supplies the endpoint, auth headers,
/// an `Encodable` request body, and decodes its own response envelope.
struct BatchTranslateClient: Sendable {
    private let endpoint: URL
    private let headers: [String: String]
    private let transport: HTTPTranslationTransport
    private let ladder: TransientRetryLadder

    init(
        endpoint: URL,
        headers: [String: String],
        transport: HTTPTranslationTransport? = nil,
        ladder: TransientRetryLadder = TransientRetryLadder()
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.transport = transport ?? HTTPTranslationTransport(timeout: 15)
        self.ladder = ladder
    }

    /// One batch request: JSON POST with the engine's auth headers, run
    /// through the transient-retry ladder; transport failures map into the
    /// engine taxonomy.
    func send<Body: Encodable & Sendable>(
        _ body: Body,
        classify: @escaping @Sendable (_ status: Int, _ body: Data) -> TranslationEngineError?,
        onRetry: (@Sendable (RetryProgress) -> Void)? = nil
    ) async throws -> Data {
        func makeRequest() throws -> URLRequest {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.httpBody = try JSONEncoder().encode(body)
            return request
        }
        let request = try makeRequest()

        do {
            return try await ladder.run({
                try await transport.send(request, classify: classify)
            }, onRetry: onRetry)
        } catch let failure as HTTPTranslationTransport.Failure {
            throw failure.engineError
        }
    }

    /// Decodes a translation batch — `texts(of:)` pulls the strings from the
    /// provider's response envelope — and guards the count; anything
    /// unparseable becomes `.badResponse`.
    static func decodeTexts<Response: Decodable>(
        _ data: Data,
        expectedCount: Int,
        as type: Response.Type,
        texts: (Response) -> [String]
    ) throws -> [String] {
        do {
            let response = try JSONDecoder().decode(type, from: data)
            let texts = texts(response)
            guard texts.count == expectedCount else {
                throw TranslationEngineError.badResponse(
                    "Expected \(expectedCount) translations, got \(texts.count)"
                )
            }
            return texts
        } catch let error as TranslationEngineError {
            throw error
        } catch {
            throw TranslationEngineError.badResponse("Unparseable response body")
        }
    }
}
