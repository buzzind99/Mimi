import Foundation

/// Manages the local dictionary files the annotation and lookup layers read.
/// Both artifacts ship compressed in the app bundle and are decompressed once
/// through the runtime's prepare FFI on first launch — no network, no build
/// step. The tokenizer dictionary (`system.dic.zst` → `ipadic.dic`) is
/// unversioned; the JMDict lookup database (`jmdict-<tag>.sqlite.zst` →
/// `jmdict-<tag>.sqlite`) carries the pin tag in its filename, which is the
/// staleness key: an app update shipping a new pin stages a *new* file and
/// stale ones are removed after the next successful promote.
///
/// Sendable by queue contract: `phases` is the only mutable state and every
/// access happens on the serial `queue` (see the `Phase` comment below).
final class DictionaryStore: @unchecked Sendable {
    static let shared = DictionaryStore()

    enum DictionaryStoreError: LocalizedError, Equatable {
        case libraryUnavailable
        case bundledDictionaryMissing
        case bundledJMDictMissing
        case prepareFailed(returnCode: Int32)
        case smokeTestFailed(reason: String)

        var errorDescription: String? {
            switch self {
            case .libraryUnavailable:
                "Dictionary runtime library not found; text renders unannotated."
            case .bundledDictionaryMissing:
                "Bundled system.dic.zst not found in the app bundle."
            case .bundledJMDictMissing:
                "Bundled \(JMDictPin.bundledFileName) not found in the app bundle."
            case let .prepareFailed(returnCode):
                "Dictionary decompression failed (return code \(returnCode))."
            case let .smokeTestFailed(reason):
                "Dictionary failed its smoke query: \(reason)."
            }
        }
    }

    // MARK: - Locations

    static let dictionaryFileName = "ipadic.dic"

    static var defaultDestinationDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mimi/dictionaries", isDirectory: true)
    }

    static var defaultDictionaryURL: URL {
        defaultDestinationDirectory.appendingPathComponent(dictionaryFileName)
    }

    /// The prepared JMDict database. The versioned filename comes straight
    /// from the pin constants (`JMDictPin.preparedFileName`) — the same
    /// constants `scripts/build_jmdict.sh` asserts against, so the two can
    /// never silently drift.
    static var defaultJMDictURL: URL {
        defaultDestinationDirectory.appendingPathComponent(JMDictPin.preparedFileName)
    }

    /// The bundled compressed tokenizer dictionary. Release builds look in
    /// the app bundle only; debug checkouts fall back to the copy fetched by
    /// `scripts/build_dictionary.sh` (Xcode runs with the checkout as working
    /// directory) so first-launch can be exercised before bundling lands.
    static var defaultBundledSource: URL? {
        bundledOrDebug(
            resource: "system", ext: "dic.zst",
            debugPath: "local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst"
        )
    }

    /// The bundled compressed JMDict artifact, same split as
    /// `defaultBundledSource` but from `scripts/build_jmdict.sh`'s output.
    static var defaultBundledJMDictSource: URL? {
        bundledOrDebug(
            resource: JMDictPin.preparedFileName, ext: "zst",
            debugPath: "local/dictionaries/\(JMDictPin.bundledFileName)"
        )
    }

    /// Bundled-resource lookup with the shared debug-checkout fallback:
    /// release builds see the app bundle only, debug checkouts fall back to
    /// the copy the build scripts leave under `local/dictionaries/`.
    private static func bundledOrDebug(
        resource: String, ext: String, debugPath: String
    ) -> URL? {
        if let bundled = Bundle.main.url(forResource: resource, withExtension: ext) {
            return bundled
        }
        #if DEBUG
            return URL(fileURLWithPath: debugPath)
        #else
            return nil
        #endif
    }

    /// The prepared dictionary, or nil when it still needs preparing.
    /// Resolution order: `MIMI_DICT` env override (debug), the Application
    /// Support location, the dev-checkout `models/ipadic.dic` (debug —
    /// `models/` is gitignored). An existing dictionary always wins so
    /// prepare() never re-prepares.
    static func resolve() -> URL? {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    /// Injectable core of `resolve()`: first candidate whose existence check
    /// passes; nil when none exist.
    static func resolve(environment: [String: String], fileExists: (URL) -> Bool) -> URL? {
        resolve(
            environmentKey: "MIMI_DICT", defaultURL: defaultDictionaryURL,
            debugCheckoutPath: "models/\(dictionaryFileName)",
            environment: environment, fileExists: fileExists
        )
    }

    /// The prepared JMDict database, or nil when it still needs preparing.
    /// Same resolution order as `resolve()` but keyed on `MIMI_JMDICT`, the
    /// versioned filename, and the `build/` intermediate the JMDict build
    /// script leaves in debug checkouts.
    static func resolveJMDict() -> URL? {
        resolveJMDict(
            environment: ProcessInfo.processInfo.environment,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    /// Injectable core of `resolveJMDict()`.
    static func resolveJMDict(environment: [String: String], fileExists: (URL) -> Bool) -> URL? {
        resolve(
            environmentKey: "MIMI_JMDICT", defaultURL: defaultJMDictURL,
            debugCheckoutPath: JMDictPin.debugCheckoutPath,
            environment: environment, fileExists: fileExists
        )
    }

    private static func resolve(
        environmentKey: String, defaultURL: URL, debugCheckoutPath: String,
        environment: [String: String], fileExists: (URL) -> Bool
    ) -> URL? {
        var candidates: [URL] = []
        #if DEBUG
            if let override = environment[environmentKey], !override.isEmpty {
                candidates.append(URL(fileURLWithPath: override))
            }
        #endif
        candidates.append(defaultURL)
        #if DEBUG
            candidates.append(URL(fileURLWithPath: debugCheckoutPath))
        #endif
        return candidates.first(where: fileExists)
    }

    // MARK: - Prepare

    /// Word certain to tokenize with a reading in any IPADIC build and carry
    /// a JMDict entry in any pin; both smoke queries require it to answer.
    private static let smokeWord = "学生"

    /// Queue-confined lifecycle, one phase per artifact. There is no
    /// `.preparing` state: every access happens on the serial queue, so
    /// concurrent prepare() calls simply line up behind the in-flight
    /// decompression and observe its outcome — that *is* the coalescing.
    private enum Phase {
        case idle
        case done(URL)
    }

    private struct Phases {
        var ipadic: Phase = .idle
        var jmDict: Phase = .idle
    }

    private let queue = DispatchQueue(label: "dev.mimi.DictionaryStore", qos: .utility)
    private let bundledSource: URL?
    private let bundledJMDictSource: URL?
    private let destinationDirectory: URL
    private let ffi: DictionaryFFI?
    private var phases = Phases()

    /// `ffi` and the locations are injectable for tests; defaults resolve the
    /// real runtime and locations. Loading the library at init is cheap
    /// (dlopen refcounts) and keeps prepare() free of lazy-binding races.
    init(
        bundledSource: URL? = DictionaryStore.defaultBundledSource,
        bundledJMDictSource: URL? = DictionaryStore.defaultBundledJMDictSource,
        destinationDirectory: URL = DictionaryStore.defaultDestinationDirectory,
        ffi: DictionaryFFI? = DictionaryFFI.load()
    ) {
        self.bundledSource = bundledSource
        self.bundledJMDictSource = bundledJMDictSource
        self.destinationDirectory = destinationDirectory
        self.ffi = ffi
    }

    /// Decompresses the bundled model if the dictionary does not exist yet;
    /// no-op afterwards. Concurrent callers coalesce on the single
    /// decompression. `completion` runs on the main queue with the dictionary
    /// URL, or an error — callers silently degrade to plain text and may
    /// retry (next launch or a later call).
    func prepare(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        run(.tokenizer, completion: completion)
    }

    /// JMDict counterpart of `prepare(completion:)`: decompresses the bundled
    /// `jmdict-<tag>.sqlite.zst` into the versioned destination, smoke-queries
    /// it through the JMDict lookup engine, and promotes it into place. The
    /// versioned filename is the staleness key — a new pin stages a new file
    /// and stale `jmdict-*.sqlite` artifacts from earlier pins are removed
    /// after a successful promote. Same coalescing: concurrent callers line
    /// up on the store's serial queue.
    func prepareJMDict(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        run(.jmDict, completion: completion)
    }

    /// One prepared artifact: its phase slot, destination filename, bundled
    /// source, and smoke check. Drives the shared prepare pipeline so the two
    /// artifacts differ only in these values.
    private enum Artifact: Equatable {
        case tokenizer
        case jmDict

        var destinationFileName: String {
            switch self {
            case .tokenizer: DictionaryStore.dictionaryFileName
            case .jmDict: JMDictPin.preparedFileName
            }
        }

        var missingSourceError: DictionaryStoreError {
            switch self {
            case .tokenizer: .bundledDictionaryMissing
            case .jmDict: .bundledJMDictMissing
            }
        }

        var phaseKeyPath: ReferenceWritableKeyPath<DictionaryStore, Phase> {
            switch self {
            case .tokenizer: \.phases.ipadic
            case .jmDict: \.phases.jmDict
            }
        }

        var sourceKeyPath: KeyPath<DictionaryStore, URL?> {
            switch self {
            case .tokenizer: \.bundledSource
            case .jmDict: \.bundledJMDictSource
            }
        }
    }

    /// Runs on the serial queue. Coalesces concurrent callers behind the
    /// phase check: a prepared artifact (done phase, or an earlier launch's
    /// file) is adopted; otherwise it is staged and promoted. A failed
    /// prepare resets the phase so a later call retries.
    private func run(
        _ artifact: Artifact, completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        queue.async {
            if case let .done(url) = self[keyPath: artifact.phaseKeyPath] {
                self.complete(completion, .success(url))
                return
            }
            let destination = self.destinationDirectory
                .appendingPathComponent(artifact.destinationFileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Prepared by an earlier launch: adopt it, don't re-decompress.
                self[keyPath: artifact.phaseKeyPath] = .done(destination)
                self.afterPrepare(artifact, promoted: destination)
                self.complete(completion, .success(destination))
                return
            }
            do {
                let url = try self.prepareArtifact(artifact, destination: destination)
                self.afterPrepare(artifact, promoted: url)
                self[keyPath: artifact.phaseKeyPath] = .done(url)
                self.complete(completion, .success(url))
            } catch {
                // Retryable: a later prepare (or next launch) starts over.
                self[keyPath: artifact.phaseKeyPath] = .idle
                self.complete(completion, .failure(error))
            }
        }
    }

    /// Post-promote hook: the JMDict artifact's versioned filename is its
    /// staleness key, so stale artifacts from earlier pins are swept after
    /// each successful promote or adoption. The tokenizer artifact has no
    /// version to sweep.
    private func afterPrepare(_ artifact: Artifact, promoted url: URL) {
        guard artifact == .jmDict else { return }
        removeLegacyJMDictArtifacts(keeping: url)
    }

    /// Async surface over the completion-based prepares above, which stay the
    /// primitives. Coalescing semantics are unchanged — the continuation
    /// lines up behind an in-flight decompression on the store's queue
    /// exactly like a completion caller would.
    func prepare() async throws -> URL {
        try await asyncFromCompletion { self.prepare(completion: $0) }
    }

    /// JMDict counterpart of `prepare() async`.
    func prepareJMDict() async throws -> URL {
        try await asyncFromCompletion { self.prepareJMDict(completion: $0) }
    }

    private func asyncFromCompletion(
        _ start: (@escaping @Sendable (Result<URL, Error>) -> Void) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // The completion runs on the main queue; resuming here hops the
            // value back to the awaiting context.
            start { result in
                continuation.resume(with: result)
            }
        }
    }

    private func complete(
        _ completion: @escaping @Sendable (Result<URL, Error>) -> Void, _ result: Result<URL, Error>
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    /// Runs on the serial queue. Stages a private copy of the artifact's zst
    /// and decompresses it into a private temp directory, smoke-checks the
    /// result, and only then promotes it into place — a failure at any stage
    /// leaves no partial file at the destination.
    private func prepareArtifact(_ artifact: Artifact, destination: URL) throws -> URL {
        guard let source = self[keyPath: artifact.sourceKeyPath] else {
            throw artifact.missingSourceError
        }
        guard let ffi else {
            throw DictionaryStoreError.libraryUnavailable
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("mimi-dictionary-prepare-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // The FFI reads the zst from disk; stage a private copy so the
        // decompress neither touches the bundle nor aliases the caller's file.
        let stagedZst = staging.appendingPathComponent("artifact.zst")
        try fm.copyItem(at: source, to: stagedZst)
        let stagedArtifact = staging.appendingPathComponent(artifact.destinationFileName)

        let returnCode = ffi.prepare(stagedZst.path, stagedArtifact.path)
        guard returnCode == 0 else {
            throw DictionaryStoreError.prepareFailed(returnCode: returnCode)
        }
        try smoke(artifact, stagedArtifact, ffi: ffi)

        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: stagedArtifact, to: destination)
        return destination
    }

    /// The artifact-specific smoke check. The tokenizer opens the staged
    /// dictionary through the FFI; the JMDict database goes through the
    /// lookup engine (`学生` must hit ≥1 entry in both).
    private func smoke(_ artifact: Artifact, _ stagedArtifact: URL, ffi: DictionaryFFI) throws {
        switch artifact {
        case .tokenizer: try smokeQuery(stagedArtifact, ffi: ffi)
        case .jmDict: try smokeQueryJMDict(stagedArtifact)
        }
    }

    /// Proves the freshly decompressed dictionary is openable and actually
    /// answers queries: the smoke word must tokenize with a non-null reading
    /// (an open-but-corrupt dictionary would not be caught by open alone).
    private func smokeQuery(_ dicURL: URL, ffi: DictionaryFFI) throws {
        guard let handle = ffi.open(dicURL.path) else {
            throw DictionaryStoreError.smokeTestFailed(reason: "open returned null")
        }
        defer { ffi.free(handle) }
        guard let tokens = ffi.tokenize(handle, Self.smokeWord) else {
            throw DictionaryStoreError.smokeTestFailed(reason: "tokenize returned null")
        }
        guard tokens.contains(where: { $0.reading != nil }) else {
            throw DictionaryStoreError.smokeTestFailed(
                reason: "no reading for \(Self.smokeWord)"
            )
        }
    }

    /// JMDict smoke check, delegated to the JMDict lookup engine: the smoke
    /// word must hit at least one entry in the staged database. A corrupt or
    /// truncated database surfaces here as the lookup's SQLite error, not as
    /// a silent pass (an open alone would succeed — SQLite opens lazily).
    private func smokeQueryJMDict(_ databaseURL: URL) throws {
        let lookup = JMDictLookup(resolveDatabase: { databaseURL })
        do {
            guard try lookup.lookup(LookupCandidate(text: Self.smokeWord)) != nil else {
                throw DictionaryStoreError.smokeTestFailed(
                    reason: "no entry for \(Self.smokeWord)"
                )
            }
        } catch let error as JMDictLookupError {
            throw DictionaryStoreError.smokeTestFailed(reason: error.localizedDescription)
        }
    }

    /// The versioned filename is the staleness key: after a successful
    /// promote (or adoption), any other prepared `jmdict-*.sqlite` in the
    /// destination directory is a stale artifact from an earlier pin and is
    /// removed — best-effort, a failed cleanup must never fail the prepare.
    private func removeLegacyJMDictArtifacts(keeping current: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: destinationDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents
            where url.lastPathComponent.hasPrefix(JMDictPin.artifactPrefix)
            && url.lastPathComponent.hasSuffix("." + JMDictPin.artifactExtension)
            && url.standardizedFileURL != current.standardizedFileURL
        {
            try? fm.removeItem(at: url)
        }
    }
}
