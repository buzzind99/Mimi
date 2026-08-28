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
/// sentence.
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
    private var results: [Int: SentenceTranslation] = [:]
    /// Guards the reentrancy window between a cancelled run unwinding and a
    /// fresh run starting: only the run holding the current generation may
    /// clear `wake` or update `inFlight`.
    private var generation = 0
    /// True while a `session.translate` call is suspended inside the worker.
    private var inFlight = false

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
        func pump() async -> Bool {
            while !pending.isEmpty {
                guard token == generation else { return false }
                let sentence = pending.removeFirst()
                setStatus(.translating)
                inFlight = true
                do {
                    let response = try await session.translate(sentence.text)
                    let pair = SentenceTranslation(
                        lang: response.targetLanguage.languageCode?.identifier ?? "en",
                        text: response.targetText)
                    results[sentence.index] = pair
                    onResult?(sentence.index, pair)
                    setStatus(.ready)
                } catch is CancellationError {
                    // Configuration invalidated / task torn down: re-queue
                    // and exit; `pending` survives for the next run.
                    pending.insert(sentence, at: 0)
                    if token == generation {
                        inFlight = false
                        setStatus(.idle)
                    }
                    return false
                } catch {
                    pending.insert(sentence, at: 0)
                    if token == generation {
                        inFlight = false
                        setStatus(.unavailable(Self.describe(error)))
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

    /// Enqueue a finalized sentence for translation.
    func enqueue(_ sentence: Sentence) {
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
    func drain(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !pending.isEmpty || inFlight {
            // A failed translator will never drain — don't make stop hang.
            if case .unavailable = status { return false }
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Drop per-session results (called when a new session starts, so stale
    /// index-keyed translations can't leak across sessions).
    func clearResults() {
        results.removeAll()
    }

    func translation(for index: Int) -> SentenceTranslation? {
        results[index]
    }

    func snapshotResults() -> [Int: SentenceTranslation] {
        results
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
                    return "The ja→en translation pack is not installed. Allow the download prompt (or install it in System Settings), then retry."
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
