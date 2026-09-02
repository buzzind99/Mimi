import Foundation

/// OpenRouter engine: chat-completions with an arbitrary user-supplied model.
///
/// Prompt contract: a strict JSON array of exactly N translations. Input is
/// ASR output, so the prompt tells the model to infer intent past recognition
/// errors. Model output is parsed defensively (code fences stripped, count +
/// non-empty validated); malformed output surfaces as `badResponse` — no
/// per-sentence fallback, since chat-completions providers are batch-native
/// and splitting would multiply rate-limited requests. No `response_format`
/// is sent: arbitrary user models may 400 on it.
struct OpenRouterEngine: TranslationEngine {
    /// Long numbered lists degrade JSON adherence and translation quality on
    /// small models — batches stay small.
    let preferredBatchSize = 8

    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let client: ChatCompletionsClient

    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let defaultModel = "tencent/hy-mt2-30b-a3b"

    init(
        apiKey: String,
        model: String,
        transport: HTTPTranslationTransport? = nil,
        ladder: TransientRetryLadder = TransientRetryLadder()
    ) {
        // An empty model string (placeholder-only Settings field) would be
        // sent verbatim and rejected by the API; fall back to the default.
        client = ChatCompletionsClient(
            config: ChatCompletionsClient.Config(
                endpoint: Self.endpoint,
                headers: ["Authorization": "Bearer \(apiKey)"],
                model: model.isEmpty ? Self.defaultModel : model
            ),
            transport: transport,
            ladder: ladder
        )
    }

    func translate(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        // One request for the whole batch; transient failures are retried by
        // the client's ladder (progress reported as `.batchRetry`).
        let content = try await client.complete(Self.messages(for: texts), onRetry: onRetry)
        return try Self.parse(content, expectedCount: texts.count)
    }

    // MARK: - Prompt + parsing

    static func messages(for texts: [String]) -> [ChatCompletionsClient.Message] {
        let system = """
        You are a Japanese-to-English translation engine. Input is ASR output and may \
        contain recognition errors or fragments — infer the intended meaning in casual \
        English. Respond with a strict JSON array of exactly one translated string per \
        input sentence, same order, nothing else.
        """
        let payload = (try? JSONEncoder().encode(texts))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let user = "Translate these \(texts.count) Japanese sentences to English:\n\(payload)"
        return [
            ChatCompletionsClient.Message(role: "system", content: system),
            ChatCompletionsClient.Message(role: "user", content: user)
        ]
    }

    /// Robust parse of the model's JSON array: strips code fences, requires
    /// the exact count and non-empty strings.
    static func parse(_ content: String, expectedCount: Int) throws -> [String] {
        guard let data = strippedFences(content).data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else {
            throw TranslationEngineError.badResponse("Model did not return a JSON array")
        }
        guard array.count == expectedCount else {
            throw TranslationEngineError.badResponse(
                "Expected \(expectedCount) translations, got \(array.count)"
            )
        }
        guard array.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TranslationEngineError.badResponse("Model returned an empty translation")
        }
        return array
    }

    /// Removes ```-fenced wrappers some models emit around JSON.
    private static func strippedFences(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        // Drop the first line (the fence + optional language tag).
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        } else {
            return text
        }
        if let fenceEnd = text.range(of: "```", options: .backwards) {
            text = String(text[..<fenceEnd.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
