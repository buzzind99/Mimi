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
/// work is funneled through this single actor: one worker loop consumes an
/// `AsyncStream` of sentences — output order can never diverge from input
/// order. Sentences are keyed by index; timestamps travel with the sentence.
///
/// The `TranslationSession` itself is provided by SwiftUI's
/// `.translationTask` (see `TranslationSessionHost`), which also drives the
/// one-time OS language-pack download prompt.
actor TranslationQueue {
    private(set) var status: TranslationStatus = .idle

    /// Sentences awaiting a session (or retrying after failure).
    private var backlog: [Sentence] = []
    private var work: AsyncStream<Sentence>.Continuation?
    private var results: [Int: SentenceTranslation] = [:]

    /// Called when a translation completes (caller's context).
    private var onResult: (@Sendable (Int, SentenceTranslation) -> Void)?
    private var onStatus: (@Sendable (TranslationStatus) -> Void)?

    /// Wire callbacks (hops to the given contexts via the caller).
    func setHandlers(
        result: @escaping @Sendable (Int, SentenceTranslation) -> Void,
        status: @escaping @Sendable (TranslationStatus) -> Void
    ) {
        onResult = result
        onStatus = status
    }

    /// SwiftUI hands us a session whenever `.translationTask` (re)fires.
    func run(with session: TranslationSession) async {
        setStatus(.ready)
        let (stream, continuation) = AsyncStream<Sentence>.makeStream()
        work = continuation
        defer {
            work = nil
        }

        // Replay anything that arrived before a session existed.
        let pending = backlog
        backlog.removeAll()
        for sentence in pending {
            continuation.yield(sentence)
        }

        for await sentence in stream {
            setStatus(.translating)
            do {
                let response = try await session.translate(sentence.text)
                let pair = SentenceTranslation(
                    lang: response.targetLanguage.languageCode?.identifier ?? "en",
                    text: response.targetText)
                results[sentence.index] = pair
                onResult?(sentence.index, pair)
                setStatus(.ready)
            } catch is CancellationError {
                // Configuration invalidated / task torn down: re-queue and exit.
                backlog.insert(sentence, at: 0)
                setStatus(.idle)
                return
            } catch {
                backlog.insert(sentence, at: 0)
                setStatus(.unavailable(Self.describe(error)))
                return
            }
        }
    }

    /// Enqueue a finalized sentence for translation.
    func enqueue(_ sentence: Sentence) {
        if let work {
            work.yield(sentence)
        } else {
            backlog.append(sentence)
        }
    }

    /// Retry after a failure: clears error state; the UI re-activates the
    /// configuration, `.translationTask` fires again, and `run(with:)`
    /// replays the backlog.
    func resetForRetry() {
        setStatus(.idle)
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
