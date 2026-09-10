import Foundation

/// One preparable dictionary artifact: the resolve probe and its builder.
private struct DictionaryArtifact<Prepare> {
    let resolve: () -> URL?
    let prepare: Prepare
}

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
        resolve: @escaping () -> URL? = { DictionaryStore.resolve() },
        resolveJMDict: @escaping () -> URL? = { DictionaryStore.resolveJMDict() },
        prepare: @escaping (@escaping @Sendable (Result<URL, Error>) -> Void) -> Void = {
            DictionaryStore.shared.prepare(completion: $0)
        },
        prepareJMDict: @escaping (@escaping @Sendable (Result<URL, Error>) -> Void) -> Void = {
            DictionaryStore.shared.prepareJMDict(completion: $0)
        }
    ) {
        typealias Prepare = (@escaping @Sendable (Result<URL, Error>) -> Void) -> Void
        // Paired with the log tag a failed fire-and-forget build reports under.
        let artifacts: [(DictionaryArtifact<Prepare>, String)] = [
            (
                DictionaryArtifact(resolve: resolve, prepare: prepare),
                "[dictionary] first-launch build failed; text stays unannotated"
            ),
            (
                DictionaryArtifact(resolve: resolveJMDict, prepare: prepareJMDict),
                "[jmdict] first-launch build failed; lookups stay unavailable"
            )
        ]
        for (artifact, log) in artifacts where artifact.resolve() == nil {
            artifact.prepare { result in
                if case let .failure(error) = result {
                    print("\(log): \(error.localizedDescription)")
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
        resolve: @escaping () -> URL? = { DictionaryStore.resolve() },
        resolveJMDict: @escaping () -> URL? = { DictionaryStore.resolveJMDict() },
        prepare: (() async throws -> URL)? = nil,
        prepareJMDict: (() async throws -> URL)? = nil
    ) async throws {
        let artifacts: [DictionaryArtifact<() async throws -> URL>] = [
            DictionaryArtifact(resolve: resolve, prepare: prepare ?? DictionaryStore.shared.prepare),
            DictionaryArtifact(
                resolve: resolveJMDict,
                prepare: prepareJMDict ?? DictionaryStore.shared.prepareJMDict
            )
        ]
        let missing = artifacts.filter { $0.resolve() == nil }
        guard !missing.isEmpty else { return }
        isPreparingDictionary = true
        defer { isPreparingDictionary = false }
        for artifact in missing {
            _ = try await artifact.prepare()
        }
    }
}
