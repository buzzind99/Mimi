import Foundation

/// OpenAI-compatible chat-completions core, factored so OpenRouter ships now
/// and OpenAI/DeepSeek/Anthropic slot in later as thin config variants:
/// each supplies an endpoint, auth headers, and a model string.
struct ChatCompletionsClient: Sendable {
    struct Message: Codable, Sendable, Equatable {
        let role: String
        let content: String
    }

    /// Everything that varies between OpenAI-compatible providers.
    struct Config: Sendable {
        let endpoint: URL
        let headers: [String: String]
        let model: String
    }

    private let config: Config
    private let transport: HTTPTranslationTransport
    private let ladder: TransientRetryLadder

    init(
        config: Config,
        transport: HTTPTranslationTransport? = nil,
        ladder: TransientRetryLadder = TransientRetryLadder(retriesBadResponse: true)
    ) {
        self.config = config
        self.transport = transport ?? HTTPTranslationTransport(timeout: 30)
        self.ladder = ladder
    }

    /// One chat completion, decoded by the caller's closure *inside* the retry
    /// ladder — decode failures share the transient-retry budget with the
    /// transport round-trip. Chat-completions providers return
    /// nondeterministic LLM output, so this client's default ladder retries
    /// `.badResponse` (fixed-contract callers can inject a plain ladder).
    func complete<T: Sendable>(
        _ messages: [Message],
        decode: @escaping @Sendable (Data) throws -> T,
        onRetry: (@Sendable (RetryProgress) -> Void)? = nil
    ) async throws -> T {
        func makeRequest() throws -> URLRequest {
            var request = URLRequest(url: config.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (name, value) in config.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.httpBody = try JSONEncoder().encode(
                ChatCompletionsRequestBody(model: config.model, messages: messages)
            )
            return request
        }
        let request = try makeRequest()

        do {
            return try await ladder.run({
                let data = try await transport.send(request, classify: { Self.classify($0, $1) })
                return try decode(data)
            }, onRetry: onRetry)
        } catch let failure as HTTPTranslationTransport.Failure {
            throw failure.engineError
        }
    }

    /// Extracts the assistant message content from the chat-completions
    /// envelope — the first step of `decode` for engines that parse the reply
    /// themselves.
    static func content(of data: Data) throws -> String {
        do {
            let response = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
            guard let content = response.choices.first?.message.content else {
                throw TranslationEngineError.badResponse("Response contained no choices")
            }
            return content
        } catch let error as TranslationEngineError {
            throw error
        } catch {
            throw TranslationEngineError.badResponse("Unparseable response body")
        }
    }

    /// Error mapping shared by every OpenAI-compatible variant: 401 invalid
    /// key, 402 quota, 429 rate limit, everything else a server error.
    static func classify(_ status: Int, _ body: Data) -> TranslationEngineError? {
        switch status {
        case 200 ... 299: nil
        case 401: .invalidKey
        case 402: .quotaExceeded
        case 429: .rateLimited
        default: .serverError(status)
        }
    }
}

private struct ChatCompletionsRequestBody: Encodable {
    let model: String
    let messages: [ChatCompletionsClient.Message]
}

private struct ChatCompletionsMessage: Decodable {
    let content: String?
}

private struct ChatCompletionsChoice: Decodable {
    let message: ChatCompletionsMessage
}

private struct ChatCompletionsResponse: Decodable {
    let choices: [ChatCompletionsChoice]
}
