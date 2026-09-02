import Foundation
import Translation

/// Translation status surfaced to the UI (non-blocking).
enum TranslationStatus: Equatable {
    case idle
    case ready
    case translating
    case unavailable(String)
}

/// Translates finalized sentences ja→en, strictly in order.
///
/// `TranslationSession.translate(_:)` throws when called concurrently, so all
/// work is funneled through this single worker loop. Untranslated sentences
/// live in the plain `pending` array — always observable on the main actor —
/// and the worker consumes them FIFO, so output order can never diverge from
/// input order. Sentences are keyed by index; timestamps travel with the
/// sentence. Repeats of already-translated sentences are served from a cache
/// at `enqueue` time and bypass the worker entirely.
///
/// The class is `@MainActor` so that `enqueue` is a synchronous call from the
/// sentence pipeline (also on the main actor): by the time `stop` calls
/// `drain`, every enqueued sentence is visible in `pending`. The worker loop
/// suspends on `session.translate` without blocking the main actor.
///
/// The `TranslationSession` itself is provided by SwiftUI's
/// `.translationTask` (see `TranslationSessionHost`), which also drives the
/// one-time OS language-pack download prompt.
@MainActor
final class TranslationQueue {
    private(set) var status: TranslationStatus = .idle

    /// The single source of truth for untranslated sentences, FIFO order.
    /// Deliberately plain state, not a buffered AsyncStream: a stream's
    /// internal buffer is invisible to `drain` and silently discarded when
    /// the task is cancelled, which would lose the final sentences on stop.
    private var pending: [Sentence] = []
    /// Wake-up signal for the worker loop (carries no data).
    private var wake: AsyncStream<Void>.Continuation?
    /// Guards the reentrancy window between a cancelled run unwinding and a
    /// fresh run starting: only the run holding the current generation may
    /// clear `wake` or update `inFlight`.
    private var generation = 0
    /// True while a `session.translate`/batch call is suspended inside the worker.
    private var inFlight = false

    /// App-run-scoped cache: repeated sentences ("よろしくお願いします"…) skip
    /// the session round-trip entirely — the result posts at `enqueue` time.
    /// NSCache's default is UNLIMITED, so `countLimit` is what bounds long
    /// sessions; entries are ≤42-char sentences (`SentenceBuffer.maxChars`).
    private let cache: NSCache<NSString, TranslationBox> = {
        let cache = NSCache<NSString, TranslationBox>()
        cache.countLimit = 200
        return cache
    }()

    /// Called when a translation completes (main-actor context).
    private var onResult: ((Int, SentenceTranslation) -> Void)?
    private var onStatus: ((TranslationStatus) -> Void)?

    /// Wire callbacks (invoked synchronously on the main actor).
    func setHandlers(
        result: @escaping (Int, SentenceTranslation) -> Void,
        status: @escaping (TranslationStatus) -> Void
    ) {
        onResult = result
        onStatus = status
    }

    /// SwiftUI hands us a session whenever `.translationTask` (re)fires.
    func run(with session: TranslationSession) async {
        generation += 1
        let token = generation
        setStatus(.ready)
        let (wakeStream, continuation) = AsyncStream<Void>.makeStream()
        wake = continuation
        defer {
            // A stale run (cancelled after a newer one entered) must not
            // clobber the live worker — guard by generation token. `pending`
            // deliberately survives so the next run replays it.
            if token == generation {
                wake = nil
                inFlight = false
            }
        }

        /// Translate everything currently in `pending`, FIFO. Returns `false`
        /// when this run must exit (stale generation, cancellation, error).
        /// Bursts (a pause flushes several finals at once) drain in batched
        /// round-trips instead of one call per sentence.
        func pump() async -> Bool {
            while !pending.isEmpty {
                guard token == generation else { return false }
                // Take a bounded slice: visible progress and a bounded
                // round-trip, while bursts still amortize the session call.
                let batch = Array(pending.prefix(16))
                pending.removeFirst(batch.count)
                setStatus(.translating)
                inFlight = true
                do {
                    for (sentence, pair) in try await translateBatch(batch, using: session) {
                        deliver(sentence, pair)
                    }
                    setStatus(.ready)
                } catch {
                    // Cancellation (configuration invalidated / task torn
                    // down) re-queues and exits like any failure; `pending`
                    // survives for the next run.
                    pending.insert(contentsOf: batch, at: 0)
                    if token == generation {
                        inFlight = false
                        if error is CancellationError {
                            setStatus(.idle)
                        } else {
                            setStatus(.unavailable(Self.describe(error)))
                        }
                    }
                    return false
                }
                inFlight = false
            }
            return true
        }

        // Replay anything that arrived before a session existed.
        guard await pump() else { return }

        // Sleep until signalled; buffered wakeups are harmless no-ops.
        for await _ in wakeStream {
            guard token == generation else { return }
            guard await pump() else { return }
        }
    }

    /// Enqueue a finalized sentence for translation. A repeat of an
    /// already-translated sentence posts its cached result synchronously and
    /// never enters `pending` (or the session round-trip).
    func enqueue(_ sentence: Sentence) {
        if let hit = cache.object(forKey: sentence.text as NSString) {
            onResult?(sentence.index, hit.value)
            return
        }
        pending.append(sentence)
        wake?.yield(())
    }

    /// Retry after a failure: clears error state; the UI re-activates the
    /// configuration, `.translationTask` fires again, and `run(with:)`
    /// replays the backlog.
    func resetForRetry() {
        setStatus(.idle)
    }

    /// Waits until `pending` is empty and no translation is in flight,
    /// bounded by `timeout`. Returns `true` when everything drained in time.
    /// Used on stop so the final sentences finish translating before teardown.
    /// `pending` is plain main-actor state, so this check observes reality.
    /// The deadline is monotonic (`ContinuousClock`) — wall-clock `Date`
    /// would skew on NTP/timezone/manual clock changes.
    func drain(timeout: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now + Duration.seconds(timeout)
        while !pending.isEmpty || inFlight {
            // A failed translator will never drain — don't make stop hang.
            if case .unavailable = status {
                return false
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Translates one batch in a single session round-trip (batches amortize
    /// the call during bursts). Returns sentences paired with translations.
    private func translateBatch(
        _ batch: [Sentence], using session: TranslationSession
    ) async throws -> [(Sentence, SentenceTranslation)] {
        if batch.count == 1 {
            let response = try await session.translate(batch[0].text)
            return [(batch[0], SentenceTranslation(
                lang: response.targetLanguage.languageCode?.identifier ?? "en",
                text: response.targetText
            ))]
        }
        let responses = try await session.translations(
            from: batch.map { TranslationSession.Request(sourceText: $0.text) }
        )
        return zip(batch, responses).map { sentence, response in
            (sentence, SentenceTranslation(
                lang: response.targetLanguage.languageCode?.identifier ?? "en",
                text: response.targetText
            ))
        }
    }

    /// Posts a result and seeds the repeat-sentence cache.
    private func deliver(_ sentence: Sentence, _ pair: SentenceTranslation) {
        cache.setObject(TranslationBox(pair), forKey: sentence.text as NSString)
        onResult?(sentence.index, pair)
    }

    private func setStatus(_ newStatus: TranslationStatus) {
        status = newStatus
        onStatus?(newStatus)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let translationError as TranslationError:
            if #available(macOS 26.0, *) {
                switch translationError {
                case TranslationError.notInstalled:
                    return "The ja→en translation pack is not installed. Allow the download "
                        + "prompt (or install it in System Settings), then retry."
                default:
                    break
                }
            }
            return translationError.errorDescription ?? "Translation failed."
        default:
            return "Translation failed: \(error.localizedDescription)"
        }
    }
}

/// NSCache stores class instances only; boxes the value-type translation.
private final class TranslationBox {
    let value: SentenceTranslation

    init(_ value: SentenceTranslation) {
        self.value = value
    }
}
