import Foundation

/// DeepL API engine. Host auto-detects from the key: a `:fx` suffix is the
/// free tier (`api-free.deepl.com`), anything else is Pro (`api.deepl.com`).
/// Key travels in the `Authorization: DeepL-Auth-Key` header. Batch `text[]`
/// with the fixed ja→en pair (`source_lang=JA`, `target_lang=EN`).
struct DeepLEngine: TranslationEngine {
    let preferredBatchSize = 32

    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let apiKey: String
    private let endpoint: URL
    private let transport: HTTPTranslationTransport
    private let ladder: TransientRetryLadder

    static let proEndpoint = URL(string: "https://api.deepl.com/v2/translate")!
    static let freeEndpoint = URL(string: "https://api-free.deepl.com/v2/translate")!

    /// `:fx` suffix marks a free-tier key.
    static func isFreeTier(_ key: String) -> Bool {
        key.hasSuffix(":fx")
    }

    static func endpoint(for key: String) -> URL {
        isFreeTier(key) ? freeEndpoint : proEndpoint
    }

    init(
        apiKey: String,
        transport: HTTPTranslationTransport? = nil,
        ladder: TransientRetryLadder = TransientRetryLadder()
    ) {
        self.apiKey = apiKey
        endpoint = Self.endpoint(for: apiKey)
        self.transport = transport ?? HTTPTranslationTransport(timeout: 15)
        self.ladder = ladder
    }

    func translate(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        func makeRequest() throws -> URLRequest {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(
                DeepLRequestBody(
                    text: texts,
                    sourceLang: "JA",
                    targetLang: "EN"
                )
            )
            return request
        }
        let request = try makeRequest()

        let data: Data
        do {
            data = try await ladder.run({
                try await transport.send(request, classify: { Self.classify($0, $1) })
            }, onRetry: onRetry)
        } catch let failure as HTTPTranslationTransport.Failure {
            throw failure.engineError
        }
        return try Self.decode(data, expectedCount: texts.count)
    }

    static func classify(_ status: Int, _ body: Data) -> TranslationEngineError? {
        switch status {
        case 200 ... 299: nil
        case 403: .invalidKey
        case 456: .quotaExceeded
        case 429: .rateLimited
        default: .serverError(status)
        }
    }

    private static func decode(_ data: Data, expectedCount: Int) throws -> [String] {
        do {
            let response = try JSONDecoder().decode(DeepLTranslateResponse.self, from: data)
            let texts = response.translations.map { $0.text }
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

private struct DeepLRequestBody: Encodable {
    let text: [String]
    let sourceLang: String
    let targetLang: String

    enum CodingKeys: String, CodingKey {
        case text
        case sourceLang = "source_lang"
        case targetLang = "target_lang"
    }
}

private struct DeepLTranslateResponse: Decodable {
    struct Item: Decodable {
        let text: String
    }

    let translations: [Item]
}
