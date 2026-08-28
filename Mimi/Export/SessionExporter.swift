import Foundation

/// Formats session transcripts: plain text, SRT, VTT, and the authoritative
/// JSON session file. Reads languages from fields; never assumes ja/en.
enum SessionExporter {
    enum Format: String, CaseIterable, Identifiable {
        case txt = "Plain text"
        case srt = "SubRip (.srt)"
        case vtt = "WebVTT (.vtt)"
        case json = "JSON session"

        var id: String { rawValue }

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

    static func plainText(entries: [SessionEntry], interleaved: Bool = true) -> String {
        var lines: [String] = []
        if interleaved {
            for entry in entries {
                let stamp = SessionClock.timestamp(entry.sentence.startS)
                lines.append("\(stamp)  \(entry.sentence.text)")
                for translation in entry.translations {
                    lines.append("\(stamp)  \(translation.text)")
                }
            }
        } else {
            for entry in entries {
                let stamp = SessionClock.timestamp(entry.sentence.startS)
                lines.append("\(stamp)  \(entry.sentence.text)")
            }
            lines.append("")
            for entry in entries {
                for translation in entry.translations {
                    let stamp = SessionClock.timestamp(entry.sentence.startS)
                    lines.append("\(stamp)  \(translation.text)")
                }
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
        let (h, m, s, ms) = components(seconds)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// VTT: `00:01:23.450` (dot ms delimiter).
    private static func vttTime(_ seconds: Double) -> String {
        let (h, m, s, ms) = components(seconds)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private static func components(_ seconds: Double) -> (Int, Int, Int, Int) {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - Double(Int(total))) * 1000)
        return (h, m, s, ms)
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
                translations: translations))
        }
        let session = JSONSession(
            startedAt: metadata?.startedAt ?? Date(),
            sourceLang: metadata?.sourceLang ?? "ja",
            targetLang: metadata?.targetLang ?? "en",
            model: metadata?.model,
            chunkMS: metadata?.chunkMS ?? 160,
            streamOffset: metadata?.streamOffset)
        let doc = JSONSessionDocument(schemaVersion: 1, session: session, sentences: sentences)
        return try encoder.encode(doc)
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
        let streamOffset: Double?

        enum CodingKeys: String, CodingKey {
            case startedAt = "started_at"
            case sourceLang = "source_lang"
            case targetLang = "target_lang"
            case model
            case chunkMS = "chunk_ms"
            case streamOffset = "stream_offset"
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
}
