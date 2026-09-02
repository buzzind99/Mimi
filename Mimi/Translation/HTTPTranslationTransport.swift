import Foundation

/// Thin `URLSession` wrapper shared by every cloud provider client.
///
/// HTTPS is enforced (no ATS exceptions exist or will be added); the injectable
/// `perform` closure replaces the whole round-trip in tests. Error responses
/// are classified into the `TranslationEngineError` taxonomy by a
/// provider-supplied closure; transport-level failures (URLSession errors,
/// cancellation) map to `.network` / `CancellationError`.
///
/// The transport never logs request headers or bodies — both carry key
/// material.
struct HTTPTranslationTransport: Sendable {
    /// A non-2xx response classified by the provider client. `retryAfter`
    /// carries the `Retry-After` header (capped at 10 s) so the retry ladder
    /// can back off accordingly; nil when absent or unparseable.
    struct Failure: Error, Sendable {
        let engineError: TranslationEngineError
        let retryAfter: TimeInterval?
    }

    private let perform: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// - Parameters:
    ///   - timeout: per-provider request timeout (Google/DeepL 15 s,
    ///     OpenRouter 30 s).
    ///   - perform: injectable round-trip for tests; nil drives a real
    ///     `URLSession` configured with the timeout.
    init(
        timeout: TimeInterval,
        perform: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        if let perform {
            self.perform = perform
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            self.perform = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw TranslationEngineError.badResponse("Non-HTTP response from provider")
                }
                return (data, http)
            }
        }
    }

    /// Performs the request. 2xx responses return the body; non-2xx throw
    /// `Failure` with the provider's classification. Only HTTPS endpoints are
    /// accepted — a plain-HTTP URL is a configuration bug, not a runtime
    /// condition, and maps to `.network`.
    func send(
        _ request: URLRequest,
        classify: @Sendable (_ status: Int, _ body: Data) -> TranslationEngineError?
    ) async throws -> Data {
        guard let url = request.url, url.scheme?.lowercased() == "https" else {
            throw TranslationEngineError.network
        }

        do {
            let (data, response) = try await perform(request)
            if let engineError = classify(response.statusCode, data) {
                throw Failure(
                    engineError: engineError,
                    retryAfter: Self.retryAfter(from: response)
                )
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            // Genuine task cancellation must stay `CancellationError`: the
            // queue treats it as a torn-down run (idle), not an outage.
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TranslationEngineError.network
        }
    }

    /// Parses `Retry-After` (seconds or HTTP-date forms are handled as
    /// seconds only — providers in play send seconds), capped at 10 s.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds > 0
        else { return nil }
        return min(seconds, 10)
    }
}
