import Foundation

/// Settings "Test" button actions, per provider. Google/DeepL run a minimal
/// one-sentence translation (cheap, exercises the real request path);
/// OpenRouter hits `GET /api/v1/key` — validates the key without spending
/// tokens. Probes run with zero transient retries so a failed test settles
/// in a single round-trip. Results land in `TranslationSettings` and render
/// inline.
enum TranslationConnectionTester {
    /// - Returns: `.success` or `.failure` with short status copy from the
    ///   engine taxonomy (never key material or raw response bodies).
    static func test(
        provider: TranslationProvider,
        key: String,
        transport: HTTPTranslationTransport? = nil
    ) async -> Result<Void, TranslationEngineError> {
        switch provider {
        case .apple:
            return .success(())
        case .google:
            return await translateProbe(
                GoogleTranslateEngine(
                    apiKey: key,
                    transport: transport,
                    ladder: TransientRetryLadder(retries: 0)
                )
            )
        case .deepl:
            return await translateProbe(
                DeepLEngine(
                    apiKey: key,
                    transport: transport,
                    ladder: TransientRetryLadder(retries: 0)
                )
            )
        case .openrouter:
            return await keyProbe(key, transport: transport)
        }
    }

    private static func translateProbe(_ engine: any TranslationEngine) async -> Result<Void, TranslationEngineError> {
        do {
            let translations = try await engine.translate(["こんにちは"])
            guard translations.allSatisfy({ !$0.isEmpty }) else {
                return .failure(.badResponse("Provider returned an empty translation"))
            }
            return .success(())
        } catch {
            return .failure(TransientRetryLadder.engineError(of: error))
        }
    }

    /// OpenRouter key validation: `GET /api/v1/key` requires a valid bearer
    /// key and costs no tokens.
    private static func keyProbe(
        _ key: String,
        transport: HTTPTranslationTransport?
    ) async -> Result<Void, TranslationEngineError> {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let transport = transport ?? HTTPTranslationTransport(timeout: 15)
        do {
            _ = try await transport.send(request, classify: ChatCompletionsClient.classify)
            return .success(())
        } catch {
            return .failure(TransientRetryLadder.engineError(of: error))
        }
    }
}
