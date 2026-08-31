import Foundation

/// Manages the local JMdict SQLite database the dictionary engine reads.
/// The dictionary data ships compressed (`JMdict_e.gz`, ~10 MB) in the app
/// bundle; on first launch the database is built from it locally through the
/// runtime's build FFI — no network, fully offline. Once built it lives at
/// `~/Library/Application Support/Mimi/dictionaries/jmdict.db` forever (a
/// never-bundled ~105 MB derived artifact).
final class DictionaryStore {
    static let shared = DictionaryStore()

    enum DictionaryStoreError: LocalizedError {
        case libraryUnavailable
        case bundledDictionaryMissing
        case buildFailed(returnCode: Int32)
        case smokeTestFailed(reason: String)

        var errorDescription: String? {
            switch self {
            case .libraryUnavailable:
                return "Dictionary runtime library not found; text renders unannotated."
            case .bundledDictionaryMissing:
                return "Bundled JMdict_e.gz not found in the app bundle."
            case let .buildFailed(returnCode):
                return "Dictionary database build failed (return code \(returnCode))."
            case let .smokeTestFailed(reason):
                return "Dictionary database failed its smoke query: \(reason)."
            }
        }
    }

    // MARK: - Locations

    static let databaseFileName = "jmdict.db"

    static var defaultDestinationDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mimi/dictionaries", isDirectory: true)
    }

    static var defaultDatabaseURL: URL {
        defaultDestinationDirectory.appendingPathComponent(databaseFileName)
    }

    /// The bundled compressed dictionary. Release builds look in the app
    /// bundle only; debug checkouts fall back to the copy fetched by
    /// `scripts/build_dictionary.sh` (Xcode runs with the checkout as working
    /// directory) so first-launch can be exercised before bundling lands.
    static var defaultBundledSource: URL? {
        if let bundled = Bundle.main.url(forResource: "JMdict_e", withExtension: "gz") {
            return bundled
        }
        #if DEBUG
            return URL(fileURLWithPath: "local/dictionaries/JMdict_e.gz")
        #else
            return nil
        #endif
    }

    /// The built database, or nil when it still needs building. Resolution
    /// order: `MIMI_JMDICT_DB` env override (debug), the Application Support
    /// location, the dev-checkout `models/jmdict.db` (debug — `models/` is
    /// gitignored). An existing database always wins so prepare() never
    /// rebuilds.
    static func resolve() -> URL? {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    /// Injectable core of `resolve()`: first candidate whose existence check
    /// passes; nil when none exist.
    static func resolve(environment: [String: String], fileExists: (URL) -> Bool) -> URL? {
        var candidates: [URL] = []
        #if DEBUG
            if let override = environment["MIMI_JMDICT_DB"], !override.isEmpty {
                candidates.append(URL(fileURLWithPath: override))
            }
        #endif
        candidates.append(defaultDatabaseURL)
        #if DEBUG
            candidates.append(URL(fileURLWithPath: "models/\(databaseFileName)"))
        #endif
        return candidates.first(where: fileExists)
    }

    // MARK: - Prepare

    /// Word certain to exist in any JMdict build (and in the test fixture);
    /// the smoke query requires it to resolve to a dictionary entry.
    private static let smokeWord = "学生"

    /// Queue-confined lifecycle. There is no `.building` state: every access
    /// happens on the serial queue, so concurrent prepare() calls simply line
    /// up behind the in-flight build and observe its outcome — that *is* the
    /// coalescing.
    private enum Phase {
        case idle
        case done(URL)
    }

    private let queue = DispatchQueue(label: "dev.mimi.DictionaryStore", qos: .utility)
    private let bundledSource: URL?
    private let destinationDirectory: URL
    private let ffi: DictionaryFFI?
    private var phase: Phase = .idle

    /// `ffi` and the locations are injectable for tests; defaults resolve the
    /// real runtime and locations. Loading the library at init is cheap
    /// (dlopen refcounts) and keeps prepare() free of lazy-binding races.
    init(
        bundledSource: URL? = DictionaryStore.defaultBundledSource,
        destinationDirectory: URL = DictionaryStore.defaultDestinationDirectory,
        ffi: DictionaryFFI? = DictionaryFFI.load()
    ) {
        self.bundledSource = bundledSource
        self.destinationDirectory = destinationDirectory
        self.ffi = ffi
    }

    /// Builds the database if it does not exist yet; no-op afterwards.
    /// Concurrent callers coalesce on the single build. `completion` runs on
    /// the main queue with the database URL, or an error — callers silently
    /// degrade to plain text and may retry (next launch or a later call).
    func prepare(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            if case let .done(url) = self.phase {
                self.complete(completion, .success(url))
                return
            }
            let destination = self.destinationDirectory
                .appendingPathComponent(Self.databaseFileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Built by an earlier launch: adopt it, don't rebuild.
                self.phase = .done(destination)
                self.complete(completion, .success(destination))
                return
            }
            do {
                let url = try self.buildDatabase(at: destination)
                self.phase = .done(url)
                self.complete(completion, .success(url))
            } catch {
                // Retryable: a later prepare() (or next launch) starts over.
                self.phase = .idle
                self.complete(completion, .failure(error))
            }
        }
    }

    private func complete(
        _ completion: @escaping (Result<URL, Error>) -> Void, _ result: Result<URL, Error>
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    /// Runs on the serial queue. Stages the gz and the fresh DB in a private
    /// temp directory, builds through the FFI, smoke-queries the result, and
    /// only then promotes it into place — a failure at any stage leaves no
    /// partial database at the destination.
    private func buildDatabase(at destination: URL) throws -> URL {
        guard let source = bundledSource else {
            throw DictionaryStoreError.bundledDictionaryMissing
        }
        guard let ffi else {
            throw DictionaryStoreError.libraryUnavailable
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("mimi-jmdict-build-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // The FFI reads the gz from disk; stage a private copy so the build
        // neither touches the bundle nor aliases the caller's file.
        let stagedGz = staging.appendingPathComponent("JMdict_e.gz")
        try fm.copyItem(at: source, to: stagedGz)
        let stagedDB = staging.appendingPathComponent(Self.databaseFileName)

        let returnCode = ffi.buildDB(stagedDB.path, stagedGz.path)
        guard returnCode == 0 else {
            throw DictionaryStoreError.buildFailed(returnCode: returnCode)
        }
        try smokeQuery(stagedDB, ffi: ffi)

        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: stagedDB, to: destination)
        return destination
    }

    /// Proves the freshly built database is openable and actually answers
    /// queries: the smoke word must tokenize to a token backed by a real
    /// dictionary entry (an empty-but-open DB would not catch a corrupt build).
    private func smokeQuery(_ dbURL: URL, ffi: DictionaryFFI) throws {
        guard let handle = ffi.open(dbURL.path) else {
            throw DictionaryStoreError.smokeTestFailed(reason: "open returned null")
        }
        defer { ffi.free(handle) }
        guard let jsonPointer = ffi.tokenizeJSON(handle, Self.smokeWord, 1) else {
            throw DictionaryStoreError.smokeTestFailed(reason: "tokenize returned null")
        }
        defer { ffi.freeString(jsonPointer) }
        guard let json = String(validatingUTF8: jsonPointer),
              let tokens = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
              as? [[String: Any]],
              tokens.contains(where: { entry in
                  let dictionaryEntry = entry["dictionary_entry"]
                  return dictionaryEntry != nil && !(dictionaryEntry is NSNull)
              })
        else {
            throw DictionaryStoreError.smokeTestFailed(
                reason: "no dictionary entry for \(Self.smokeWord)"
            )
        }
    }
}
