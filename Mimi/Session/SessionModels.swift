import Foundation

/// A finalized sentence. Immutable value type; crosses thread boundaries.
struct Sentence: Identifiable, Equatable, Sendable {
    /// Stable index; keys JP↔EN alignment.
    let index: Int
    /// Session-relative start time in seconds (first chunk's sample offset).
    let startS: Double
    /// Session-relative end time in seconds (last chunk's offset + duration).
    let endS: Double
    /// Per-sentence language (BCP-47, e.g. "ja").
    let lang: String
    let text: String

    var id: Int {
        index
    }
}

/// A translation for a sentence. `translations` is append-only by design
/// (future multi-target support).
struct SentenceTranslation: Equatable, Codable, Sendable {
    let lang: String
    let text: String
}

/// ASR streaming events delivered from the ASR queue.
enum ASREvent: Sendable {
    case partial(text: String)
    case final(text: String, startSample: Int, endSample: Int, lang: String)
}

/// A complete session row: sentence + its (possibly empty) translations.
/// Display strings (timestamps, joined translations) are precomputed at
/// mutation time so row rendering never re-joins or re-formats.
struct SessionEntry: Identifiable, Equatable {
    let sentence: Sentence
    var translations: [SentenceTranslation] = []
    /// Formatted once at init for cheap row rendering.
    let startTimestamp: String
    let endTimestamp: String
    /// `nil` while untranslated; the row renders a placeholder instead.
    private(set) var joinedTranslations: String?

    init(sentence: Sentence) {
        self.sentence = sentence
        startTimestamp = SessionClock.timestamp(sentence.startS)
        endTimestamp = SessionClock.timestamp(sentence.endS)
    }

    mutating func appendTranslation(_ translation: SentenceTranslation) {
        translations.append(translation)
        joinedTranslations = translations.map(\.text).joined(separator: " / ")
    }

    var id: Int {
        sentence.index
    }
}

/// Session metadata captured at Start.
struct SessionMetadata: Equatable, Codable {
    var startedAt: Date
    var sourceLang: String?
    var targetLang: String?
    var model: String?
    var chunkMS: Int
}

enum SessionClock {
    static let sampleRate: Double = 16000

    static func seconds(_ sample: Int) -> Double {
        Double(sample) / sampleRate
    }

    /// Formats session-relative seconds as `HH:MM:SS` (or `MM:SS` under 1 h).
    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
