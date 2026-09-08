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
                return "Dictionary runtime library not found; text renders unannotated."
            case .bundledDictionaryMissing:
                return "Bundled system.dic.zst not found in the app bundle."
            case .bundledJMDictMissing:
                return "Bundled \(JMDictPin.bundledFileName) not found in the app bundle."
            case let .prepareFailed(returnCode):
                return "Dictionary decompression failed (return code \(returnCode))."
            case let .smokeTestFailed(reason):
                return "Dictionary failed its smoke query: \(reason)."
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
        if let bundled = Bundle.main.url(forResource: "system", withExtension: "dic.zst") {
            return bundled
        }
        #if DEBUG
            return URL(fileURLWithPath: "local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst")
        #else
            return nil
        #endif
    }

    /// The bundled compressed JMDict artifact, same split as
    /// `defaultBundledSource` but from `scripts/build_jmdict.sh`'s output.
    static var defaultBundledJMDictSource: URL? {
        if let bundled = Bundle.main.url(
            forResource: JMDictPin.preparedFileName, withExtension: "zst"
        ) {
            return bundled
        }
        #if DEBUG
            return URL(fileURLWithPath: "local/dictionaries/\(JMDictPin.bundledFileName)")
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
            debugCheckoutPath: "build/\(JMDictPin.preparedFileName)",
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

    /// Word certain to tokenize with a reading in any IPADIC build; the smoke
    /// query requires it to come back with a non-null reading.
    private static let smokeWord = "学生"

    /// Word certain to carry a JMDict entry in any pin; the JMDict smoke
    /// query runs the JMDict lookup (`JMDictLookup`) over the freshly
    /// decompressed database and requires it to hit.
    private static let jmDictSmokeWord = "学生"

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
        queue.async {
            if case let .done(url) = self.phases.ipadic {
                self.complete(completion, .success(url))
                return
            }
            let destination = self.destinationDirectory
                .appendingPathComponent(Self.dictionaryFileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Prepared by an earlier launch: adopt it, don't re-decompress.
                self.phases.ipadic = .done(destination)
                self.complete(completion, .success(destination))
                return
            }
            do {
                let url = try self.prepareDictionary(at: destination)
                self.phases.ipadic = .done(url)
                self.complete(completion, .success(url))
            } catch {
                // Retryable: a later prepare() (or next launch) starts over.
                self.phases.ipadic = .idle
                self.complete(completion, .failure(error))
            }
        }
    }

    /// JMDict counterpart of `prepare(completion:)`: decompresses the bundled
    /// `jmdict-<tag>.sqlite.zst` into the versioned destination, smoke-queries
    /// it through the JMDict lookup engine, and promotes it into place. The
    /// versioned filename is the staleness key — a new pin stages a new file
    /// and stale `jmdict-*.sqlite` artifacts from earlier pins are removed
    /// after a successful promote. Same coalescing: concurrent callers line
    /// up on the store's serial queue.
    func prepareJMDict(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        queue.async {
            let destination = self.destinationDirectory
                .appendingPathComponent(JMDictPin.preparedFileName)
            let adopt: Bool
            if case let .done(url) = self.phases.jmDict {
                self.complete(completion, .success(url))
                return
            } else if FileManager.default.fileExists(atPath: destination.path) {
                // Prepared by an earlier launch: adopt it, don't re-decompress.
                self.phases.jmDict = .done(destination)
                adopt = true
            } else {
                adopt = false
            }
            if adopt {
                self.removeLegacyJMDictArtifacts(keeping: destination)
                self.complete(completion, .success(destination))
                return
            }
            do {
                let url = try self.prepareJMDictDictionary(at: destination)
                self.removeLegacyJMDictArtifacts(keeping: url)
                self.phases.jmDict = .done(url)
                self.complete(completion, .success(url))
            } catch {
                // Retryable: a later prepareJMDict() (or next launch) starts over.
                self.phases.jmDict = .idle
                self.complete(completion, .failure(error))
            }
        }
    }

    /// Async surface over the completion-based `prepare(completion:)` above,
    /// which stays the primitive. Coalescing semantics are unchanged — the
    /// continuation lines up behind an in-flight decompression on the store's
    /// queue exactly like a completion caller would.
    func prepare() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            prepare { result in
                // The completion runs on the main queue; resuming here hops
                // the value back to the awaiting context.
                continuation.resume(with: result)
            }
        }
    }

    /// Async surface over `prepareJMDict(completion:)`, mirroring
    /// `prepare() async`.
    func prepareJMDict() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            prepareJMDict { result in
                continuation.resume(with: result)
            }
        }
    }

    private func complete(
        _ completion: @escaping @Sendable (Result<URL, Error>) -> Void, _ result: Result<URL, Error>
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    /// Runs on the serial queue. Stages a private copy of the tokenizer zst
    /// and decompresses into a private temp directory, smoke-opens the result,
    /// and only then promotes it into place — a failure at any stage leaves
    /// no partial dictionary at the destination.
    private func prepareDictionary(at destination: URL) throws -> URL {
        try prepareArtifact(
            source: bundledSource, missingSourceError: .bundledDictionaryMissing,
            fileName: Self.dictionaryFileName, destination: destination
        ) { stagedArtifact, ffi in
            try self.smokeQuery(stagedArtifact, ffi: ffi)
        }
    }

    /// JMDict counterpart of `prepareDictionary(at:)`: same stage → decompress
    /// → promote discipline, but the smoke check runs the JMDict lookup
    /// engine against the staged SQLite database (`学生` must hit ≥1 entry)
    /// instead of the tokenizer FFI.
    private func prepareJMDictDictionary(at destination: URL) throws -> URL {
        try prepareArtifact(
            source: bundledJMDictSource, missingSourceError: .bundledJMDictMissing,
            fileName: JMDictPin.preparedFileName, destination: destination
        ) { stagedArtifact, _ in
            try self.smokeQueryJMDict(stagedArtifact)
        }
    }

    /// Shared stage → decompress → smoke → promote pipeline for both
    /// artifacts. Runs on the serial queue; `smoke` receives the freshly
    /// decompressed artifact in its private staging directory. Returns the
    /// promoted destination URL.
    private func prepareArtifact(
        source: URL?, missingSourceError: DictionaryStoreError, fileName: String,
        destination: URL, smoke: (URL, DictionaryFFI) throws -> Void
    ) throws -> URL {
        guard let source else {
            throw missingSourceError
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
        let stagedArtifact = staging.appendingPathComponent(fileName)

        let returnCode = ffi.prepare(stagedZst.path, stagedArtifact.path)
        guard returnCode == 0 else {
            throw DictionaryStoreError.prepareFailed(returnCode: returnCode)
        }
        try smoke(stagedArtifact, ffi)

        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: stagedArtifact, to: destination)
        return destination
    }

    /// Proves the freshly decompressed dictionary is openable and actually
    /// answers queries: the smoke word must tokenize with a non-null reading
    /// (an open-but-corrupt dictionary would not be caught by open alone).
    private func smokeQuery(_ dicURL: URL, ffi: DictionaryFFI) throws {
        guard let handle = ffi.open(dicURL.path) else {
            throw DictionaryStoreError.smokeTestFailed(reason: "open returned null")
        }
        defer { ffi.free(handle) }
        guard let jsonPointer = ffi.tokenizeJSON(handle, Self.smokeWord) else {
            throw DictionaryStoreError.smokeTestFailed(reason: "tokenize returned null")
        }
        defer { ffi.freeString(jsonPointer) }
        guard let json = String(validatingCString: jsonPointer),
              let tokens = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
              as? [[String: Any]],
              tokens.contains(where: { entry in
                  let reading = entry["reading"]
                  return reading != nil && !(reading is NSNull)
              })
        else {
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
            guard try lookup.lookup(LookupCandidate(text: Self.jmDictSmokeWord)) != nil else {
                throw DictionaryStoreError.smokeTestFailed(
                    reason: "no entry for \(Self.jmDictSmokeWord)"
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
            where url.lastPathComponent.hasPrefix("jmdict-")
            && url.lastPathComponent.hasSuffix(".sqlite")
            && url.standardizedFileURL != current.standardizedFileURL
        {
            try? fm.removeItem(at: url)
        }
    }
}
