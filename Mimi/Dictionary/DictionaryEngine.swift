import Foundation

/// One token from the dictionary tokenizer, decoded from the runtime's JSON
/// payload — `{text, start, end, reading}`.
///
/// `start`/`end` are Unicode-scalar indices into the **original** input
/// (end-exclusive). The runtime performs no normalization, so spans must be
/// sliced via `unicodeScalars` — never `String.Index` or `Character` views.
struct DictionaryToken: Codable, Equatable {
    let text: String
    let start: Int
    let end: Int
    /// The surface's reading in hiragana (conjugated forms carry their own —
    /// 見た → 見/ミ + た/タ), or nil for unknown/unreadable surfaces (names,
    /// rare ideographs, punctuation, bare Latin).
    let reading: String?
}

/// Swift wrapper around the staged dictionary runtime. Opens one
/// process-global dictionary handle lazily on the resolved dictionary URL and
/// never frees it during the app's lifetime (the CrispASR keep-warm stance).
/// Every failure is fail-soft: `tokenize` returns nil and callers degrade to
/// plain text rather than crash.
///
/// Sendable by locking contract: `ffi` and `resolveDictionary` are set once in
/// init and never mutated; the only mutable state (`handle`) is guarded by
/// `lock` (see the comment there).
final class DictionaryEngine: @unchecked Sendable {
    static let shared = DictionaryEngine()

    private static let decoder = JSONDecoder()

    private let lock = NSLock()
    private let ffi: DictionaryFFI?
    private let resolveDictionary: () -> URL?
    /// Guarded by `lock`. Opened on first use; a failed attempt is retried on
    /// the next call (the dictionary may still be preparing on first launch).
    private var handle: UnsafeMutableRawPointer?

    /// `ffi` and the dictionary resolver are injectable for tests; defaults
    /// resolve the real runtime and the store's dictionary locations.
    init(
        ffi: DictionaryFFI? = DictionaryFFI.load(),
        resolveDictionary: @escaping () -> URL? = { DictionaryStore.resolve() }
    ) {
        self.ffi = ffi
        self.resolveDictionary = resolveDictionary
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
                return String(validatingCString: pointer).map { Data($0.utf8) }
            }
        }
        guard let payload else { return nil }
        return try? Self.decoder.decode([DictionaryToken].self, from: payload)
    }

    /// Lock-held. Resolves the dictionary URL and opens the handle on first
    /// use; keeps the handle warm forever afterwards.
    private func openedHandle(ffi: DictionaryFFI) -> UnsafeMutableRawPointer? {
        if let handle {
            return handle
        }
        guard let url = resolveDictionary(), let opened = ffi.open(url.path) else {
            return nil
        }
        handle = opened
        return opened
    }
}
