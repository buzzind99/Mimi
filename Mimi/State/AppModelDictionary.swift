import Foundation

/// Dictionary preparation surface of `AppModel` (file split for the lint
/// gate): the first-launch kick-off of both artifacts and the session-start
/// gate that blocks on either missing one.
extension AppModel {
    /// Kicks the first-launch dictionary preparations — the tokenizer
    /// dictionary (bundled `system.dic.zst` → decompressed dictionary, see
    /// `DictionaryStore`) and the JMDict lookup database
    /// (`jmdict-<tag>.sqlite.zst` → versioned SQLite file) — in the
    /// background so ruby annotations and lookups come up soon after
    /// startup. The two artifacts are covered independently: one resolving
    /// does not excuse the other. Purely opportunistic: until it succeeds
    /// (or if it never does) text renders unannotated and lookups fail
    /// soft, so failures are logged only and retried on the next launch.
    /// The `resolve`/`prepare` pairs are injectable for tests; the defaults
    /// drive the real store.
    func prepareDictionaryIfNeeded(
        resolve: () -> URL? = { DictionaryStore.resolve() },
        resolveJMDict: () -> URL? = { DictionaryStore.resolveJMDict() },
        prepare: ((@escaping @Sendable (Result<URL, Error>) -> Void) -> Void) = {
            DictionaryStore.shared.prepare(completion: $0)
        },
        prepareJMDict: ((@escaping @Sendable (Result<URL, Error>) -> Void) -> Void) = {
            DictionaryStore.shared.prepareJMDict(completion: $0)
        }
    ) {
        if resolve() == nil {
            prepare { result in
                if case let .failure(error) = result {
                    print(
                        "[dictionary] first-launch build failed; text stays unannotated: \(error.localizedDescription)"
                    )
                }
            }
        }
        if resolveJMDict() == nil {
            prepareJMDict { result in
                if case let .failure(error) = result {
                    print(
                        "[jmdict] first-launch build failed; lookups stay unavailable: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Session-start gate: a session must never run while furigana or
    /// dictionary lookups are silently missing, so either missing database
    /// is built before capture begins. The launch-time kick
    /// (`prepareDictionaryIfNeeded`, above) usually finishes the builds
    /// first; this coalesces behind in-flight builds on the store's queue
    /// and only blocks when none is running. A failed build throws so the
    /// start fails visibly in the status bar (pressing Start again
    /// retries). The `resolve`/`prepare` pairs are injectable for tests;
    /// the defaults drive the real store's async surface.
    func ensureDictionaryReady(
        resolve: () -> URL? = { DictionaryStore.resolve() },
        resolveJMDict: () -> URL? = { DictionaryStore.resolveJMDict() },
        prepare: (() async throws -> URL)? = nil,
        prepareJMDict: (() async throws -> URL)? = nil
    ) async throws {
        let needsIPADIC = resolve() == nil
        let needsJMDict = resolveJMDict() == nil
        guard needsIPADIC || needsJMDict else { return }
        isPreparingDictionary = true
        defer { isPreparingDictionary = false }
        if needsIPADIC {
            _ = try await(prepare ?? DictionaryStore.shared.prepare)()
        }
        if needsJMDict {
            _ = try await(prepareJMDict ?? DictionaryStore.shared.prepareJMDict)()
        }
    }
}
