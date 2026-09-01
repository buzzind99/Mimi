import Foundation

/// One token from the dictionary tokenizer, decoded from the runtime's JSON
/// payload. Only the fields Mimi consumes are decoded — senses, match ranges
/// and deinflection reasons are skipped to keep the payload cheap.
///
/// `start`/`end` are Unicode-scalar indices into the **original** input
/// (end-exclusive). The runtime performs no normalization, so spans must be
/// sliced via `unicodeScalars` — never `String.Index` or `Character` views.
struct DictionaryToken: Codable, Equatable {
    let text: String
    let start: Int
    let end: Int
    /// The JMdict entry backing the token, or nil for unmatched surfaces
    /// (names, punctuation, bare digits).
    let dictionaryEntry: Entry?

    struct Entry: Codable, Equatable {
        let kanjiReadings: [KanjiReading]
        let kanaReadings: [KanaReading]

        enum CodingKeys: String, CodingKey {
            case kanjiReadings = "kanji_readings"
            case kanaReadings = "kana_readings"
        }
    }

    struct KanjiReading: Codable, Equatable {
        let text: String
    }

    /// A candidate reading. `priority`/`info`/`matched` carry the flags the
    /// annotator's selection rule needs (prefer surface-exact, then highest
    /// priority, never a "search-only" form).
    struct KanaReading: Codable, Equatable {
        let text: String
        let priority: String?
        let info: String?
        let matched: Bool
    }

    enum CodingKeys: String, CodingKey {
        case text, start, end
        case dictionaryEntry = "dictionary_entry"
    }
}

/// Swift wrapper around the staged dictionary runtime. Opens one
/// process-global database handle lazily on the resolved database URL and
/// never frees it during the app's lifetime (the CrispASR keep-warm stance).
/// Every failure is fail-soft: `tokenize` returns nil and callers degrade to
/// plain text rather than crash.
final class DictionaryEngine {
    static let shared = DictionaryEngine()

    private let lock = NSLock()
    private let ffi: DictionaryFFI?
    private let resolveDatabase: () -> URL?
    /// Guarded by `lock`. Opened on first use; a failed attempt is retried on
    /// the next call (the database may still be building on first launch).
    private var handle: UnsafeMutableRawPointer?

    /// `ffi` and the database resolver are injectable for tests; defaults
    /// resolve the real runtime and the store's database locations.
    init(
        ffi: DictionaryFFI? = DictionaryFFI.load(),
        resolveDatabase: @escaping () -> URL? = { DictionaryStore.resolve() }
    ) {
        self.ffi = ffi
        self.resolveDatabase = resolveDatabase
    }

    /// Tokenizes `text` into dictionary-backed tokens, or nil when the
    /// runtime, dictionary, payload, or decoding is unavailable.
    func tokenize(_ text: String) -> [DictionaryToken]? {
        guard let ffi else { return nil }
        let payload: Data? = lock.withLock {
            guard let handle = openedHandle(ffi: ffi) else { return nil }
            return text.withCString { cText in
                guard let pointer = ffi.tokenizeJSON(handle, cText) else {
                    return nil
                }
                defer { ffi.freeString(pointer) }
                return String(validatingUTF8: pointer).map { Data($0.utf8) }
            }
        }
        guard let payload else { return nil }
        return try? JSONDecoder().decode([DictionaryToken].self, from: payload)
    }

    /// Lock-held. Resolves the database URL and opens the handle on first
    /// use; keeps the handle warm forever afterwards.
    private func openedHandle(ffi: DictionaryFFI) -> UnsafeMutableRawPointer? {
        if let handle {
            return handle
        }
        guard let url = resolveDatabase(), let opened = ffi.open(url.path) else {
            return nil
        }
        handle = opened
        return opened
    }
}
