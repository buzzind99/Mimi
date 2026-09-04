import Foundation

/// DeepL API engine. Host auto-detects from the key: a `:fx` suffix is the
/// free tier (`api-free.deepl.com`), anything else is Pro (`api.deepl.com`).
/// Key travels in the `Authorization: DeepL-Auth-Key` header. Batch `text[]`
/// with the fixed ja→en pair (`source_lang=JA`, `target_lang=EN`).
struct DeepLEngine: TranslationEngine {
    let preferredBatchSize = 32

    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let client: BatchTranslateClient

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
        client = BatchTranslateClient(
            endpoint: Self.endpoint(for: apiKey),
            headers: ["Authorization": "DeepL-Auth-Key \(apiKey)"],
            transport: transport,
            ladder: ladder
        )
    }

    func translate(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let data = try await client.send(
            DeepLRequestBody(text: texts, sourceLang: "JA", targetLang: "EN"),
            classify: Self.classify,
            onRetry: onRetry
        )
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
        try BatchTranslateClient.decodeTexts(
            data, expectedCount: expectedCount, as: DeepLTranslateResponse.self
        ) { $0.translations.map(\.text) }
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
