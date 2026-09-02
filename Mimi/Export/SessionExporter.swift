import Foundation

/// Formats session transcripts: plain text, SRT, VTT, and the authoritative
/// JSON session file. Reads languages from fields; never assumes ja/en.
enum SessionExporter {
    enum Format: String, CaseIterable, Identifiable {
        case txt = "Plain text"
        case srt = "SubRip (.srt)"
        case vtt = "WebVTT (.vtt)"
        case json = "JSON session"

        var id: String {
            rawValue
        }

        var fileExtension: String {
            switch self {
            case .txt: return "txt"
            case .srt: return "srt"
            case .vtt: return "vtt"
            case .json: return "json"
            }
        }
    }

    // MARK: - Plain text

    static func plainText(entries: [SessionEntry]) -> String {
        var lines: [String] = []
        for entry in entries {
            let stamp = SessionClock.timestamp(entry.sentence.startS)
            lines.append("\(stamp)  \(entry.sentence.text)")
            for translation in entry.translations {
                lines.append("\(stamp)  \(translation.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - SRT / VTT

    static func subtitles(entries: [SessionEntry], format: Format) -> String {
        precondition(format == .srt || format == .vtt)
        var out = format == .vtt ? "WEBVTT\n\n" : ""
        var cueIndex = 1
        for entry in entries {
            // EN cue line first (JP optionally as a second line).
            let translations = entry.translations
            guard !translations.isEmpty else { continue }
            let start = format == .srt
                ? srtTime(entry.sentence.startS) : vttTime(entry.sentence.startS)
            let end = format == .srt
                ? srtTime(entry.sentence.endS) : vttTime(entry.sentence.endS)
            out += "\(cueIndex)\n"
            out += "\(start) --> \(end)\n"
            out += translations.map(\.text).joined(separator: "\n")
            out += "\n\n"
            cueIndex += 1
        }
        return out
    }

    /// SRT: `00:01:23,450` (comma ms delimiter).
    private static func srtTime(_ seconds: Double) -> String {
        let c = components(seconds)
        return String(format: "%02d:%02d:%02d,%03d", c.h, c.m, c.s, c.ms)
    }

    /// VTT: `00:01:23.450` (dot ms delimiter).
    private static func vttTime(_ seconds: Double) -> String {
        let c = components(seconds)
        return String(format: "%02d:%02d:%02d.%03d", c.h, c.m, c.s, c.ms)
    }

    private struct TimeComponents {
        let h: Int
        let m: Int
        let s: Int
        let ms: Int
    }

    private static func components(_ seconds: Double) -> TimeComponents {
        let total = max(0, seconds)
        let whole = Int(total)
        return TimeComponents(
            h: whole / 3600,
            m: (whole % 3600) / 60,
            s: whole % 60,
            ms: Int((total - Double(whole)) * 1000)
        )
    }

    // MARK: - JSON session (authoritative interchange format, v1)

    static func json(
        entries: [SessionEntry],
        metadata: SessionMetadata?,
        results: [Int: SentenceTranslation]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var sentences: [JSONSentence] = []
        for entry in entries {
            var translations = entry.translations
            if translations.isEmpty, let pending = results[entry.sentence.index] {
                translations = [pending]
            }
            sentences.append(JSONSentence(
                index: entry.sentence.index,
                startS: entry.sentence.startS,
                endS: entry.sentence.endS,
                lang: entry.sentence.lang,
                transcript: entry.sentence.text,
                translations: translations
            ))
        }
        let session = JSONSession(
            startedAt: metadata?.startedAt ?? Date(),
            sourceLang: metadata?.sourceLang ?? "ja",
            targetLang: metadata?.targetLang ?? "en",
            model: metadata?.model,
            chunkMS: metadata?.chunkMS ?? 160
        )
        let doc = JSONSessionDocument(schemaVersion: 1, session: session, sentences: sentences)
        return try encoder.encode(doc)
    }
}

// MARK: - Document shape (forward-compatible; languages read from fields)

struct JSONSessionDocument: Codable {
    let schemaVersion: Int
    let session: JSONSession
    let sentences: [JSONSentence]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case session
        case sentences
    }
}

struct JSONSession: Codable {
    let startedAt: Date
    let sourceLang: String?
    let targetLang: String?
    let model: String?
    let chunkMS: Int

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case sourceLang = "source_lang"
        case targetLang = "target_lang"
        case model
        case chunkMS = "chunk_ms"
    }
}

struct JSONSentence: Codable {
    let index: Int
    let startS: Double
    let endS: Double
    let lang: String
    let transcript: String
    let translations: [SentenceTranslation]

    enum CodingKeys: String, CodingKey {
        case index
        case startS = "start_s"
        case endS = "end_s"
        case lang
        case transcript
        case translations
    }
}
