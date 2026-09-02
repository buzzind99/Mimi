import Foundation

/// Google Cloud Translation v2 engine. Key travels in the `X-goog-api-key`
/// header (never the query string, which would leak it into logs). Batch
/// `q[]` with `format=text`, fixed ja→en. The v2 API HTML-escapes output
/// (`&#39;`, `&quot;`, …), so results are unescaped before returning.
struct GoogleTranslateEngine: TranslationEngine {
    let preferredBatchSize = 32

    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let apiKey: String
    private let transport: HTTPTranslationTransport
    private let ladder: TransientRetryLadder

    static let endpoint = URL(string: "https://translation.googleapis.com/language/translate/v2")!

    init(
        apiKey: String,
        transport: HTTPTranslationTransport? = nil,
        ladder: TransientRetryLadder = TransientRetryLadder()
    ) {
        self.apiKey = apiKey
        self.transport = transport ?? HTTPTranslationTransport(timeout: 15)
        self.ladder = ladder
    }

    func translate(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        func makeRequest() throws -> URLRequest {
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "X-goog-api-key")
            request.httpBody = try JSONEncoder().encode(
                GoogleRequestBody(q: texts, format: "text", source: "ja", target: "en")
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
        let decoded = try Self.decode(data, expectedCount: texts.count)
        return decoded.map(Self.decodingHTMLEntities)
    }

    /// HTTP status → taxonomy. 400 covers both malformed requests and the
    /// "API key not valid" shape Google returns as 400.
    static func classify(_ status: Int, _ body: Data) -> TranslationEngineError? {
        switch status {
        case 200 ... 299: nil
        case 400, 403: .invalidKey
        case 429: .rateLimited
        default: .serverError(status)
        }
    }

    private static func decode(_ data: Data, expectedCount: Int) throws -> [String] {
        do {
            let response = try JSONDecoder().decode(GoogleTranslateResponse.self, from: data)
            let texts = response.data.translations.map { $0.translatedText }
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

private struct GoogleRequestBody: Encodable {
    let q: [String]
    let format: String
    let source: String
    let target: String
}

private struct GoogleTranslateResponse: Decodable {
    struct Item: Decodable {
        let translatedText: String
    }

    struct DataPayload: Decodable {
        let translations: [Item]
    }

    let data: DataPayload
}

extension GoogleTranslateEngine {
    /// Unescapes the HTML entities the v2 API applies to `translatedText`.
    /// Numeric and named entities decode first; `&amp;` last, so an escaped
    /// entity (`&amp;#39;`) is not double-decoded.
    static func decodingHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = replaceNumericEntities(text)

        let named = [
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&nbsp;": "\u{00A0}"
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func replaceNumericEntities(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&",
                  let (scalar, end) = numericEntity(at: index, in: text)
            else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            result.append(Character(scalar))
            index = end
        }
        return result
    }

    /// Matches `&#NNNN;` (decimal) or `&#xHHHH;` (hex) at `index`. Surrogate
    /// halves and out-of-range values are left as-is (Google only escapes
    /// ASCII-range characters in practice).
    private static func numericEntity(at index: String.Index, in text: String) -> (Unicode.Scalar, String.Index)? {
        var cursor = text.index(after: index)
        guard cursor < text.endIndex, text[cursor] == "#" else { return nil }
        cursor = text.index(after: cursor)

        var radix = 10
        if cursor < text.endIndex, text[cursor] == "x" || text[cursor] == "X" {
            radix = 16
            cursor = text.index(after: cursor)
        }

        let digitsStart = cursor
        while cursor < text.endIndex, text[cursor].isHexDigit {
            cursor = text.index(after: cursor)
        }
        guard cursor > digitsStart, cursor < text.endIndex, text[cursor] == ";" else { return nil }

        let digits = String(text[digitsStart ..< cursor])
        let surrogateRange = UInt32(0xD800) ... UInt32(0xDFFF)
        guard let value = UInt32(digits, radix: radix),
              !surrogateRange.contains(value),
              let scalar = Unicode.Scalar(value)
        else { return nil }
        return (scalar, text.index(after: cursor))
    }
}
