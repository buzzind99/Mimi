import Foundation

/// Manages the local dictionary file the tokenizer engine reads. The
/// dictionary data ships compressed (`system.dic.zst`, ~8 MB) in the app
/// bundle; on first launch it is decompressed once through the runtime's
/// prepare FFI — no network, no build step. Once prepared it lives at
/// `~/Library/Application Support/Mimi/dictionaries/ipadic.dic` forever.
final class DictionaryStore {
    static let shared = DictionaryStore()

    enum DictionaryStoreError: LocalizedError, Equatable {
        case libraryUnavailable
        case bundledDictionaryMissing
        case prepareFailed(returnCode: Int32)
        case smokeTestFailed(reason: String)

        var errorDescription: String? {
            switch self {
            case .libraryUnavailable:
                return "Dictionary runtime library not found; text renders unannotated."
            case .bundledDictionaryMissing:
                return "Bundled system.dic.zst not found in the app bundle."
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

    /// The bundled compressed dictionary. Release builds look in the app
    /// bundle only; debug checkouts fall back to the copy fetched by
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
        var candidates: [URL] = []
        #if DEBUG
            if let override = environment["MIMI_DICT"], !override.isEmpty {
                candidates.append(URL(fileURLWithPath: override))
            }
        #endif
        candidates.append(defaultDictionaryURL)
        #if DEBUG
            candidates.append(URL(fileURLWithPath: "models/\(dictionaryFileName)"))
        #endif
        return candidates.first(where: fileExists)
    }

    // MARK: - Prepare

    /// Word certain to tokenize with a reading in any IPADIC build; the smoke
    /// query requires it to come back with a non-null reading.
    private static let smokeWord = "学生"

    /// Queue-confined lifecycle. There is no `.preparing` state: every access
    /// happens on the serial queue, so concurrent prepare() calls simply line
    /// up behind the in-flight decompression and observe its outcome — that
    /// *is* the coalescing.
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

    /// Decompresses the bundled model if the dictionary does not exist yet;
    /// no-op afterwards. Concurrent callers coalesce on the single
    /// decompression. `completion` runs on the main queue with the dictionary
    /// URL, or an error — callers silently degrade to plain text and may
    /// retry (next launch or a later call).
    func prepare(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            if case let .done(url) = self.phase {
                self.complete(completion, .success(url))
                return
            }
            let destination = self.destinationDirectory
                .appendingPathComponent(Self.dictionaryFileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Prepared by an earlier launch: adopt it, don't re-decompress.
                self.phase = .done(destination)
                self.complete(completion, .success(destination))
                return
            }
            do {
                let url = try self.prepareDictionary(at: destination)
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

    /// Runs on the serial queue. Stages a private copy of the zst and
    /// decompresses into a private temp directory, smoke-opens the result,
    /// and only then promotes it into place — a failure at any stage leaves
    /// no partial dictionary at the destination.
    private func prepareDictionary(at destination: URL) throws -> URL {
        guard let source = bundledSource else {
            throw DictionaryStoreError.bundledDictionaryMissing
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
        let stagedZst = staging.appendingPathComponent("system.dic.zst")
        try fm.copyItem(at: source, to: stagedZst)
        let stagedDic = staging.appendingPathComponent(Self.dictionaryFileName)

        let returnCode = ffi.prepare(stagedZst.path, stagedDic.path)
        guard returnCode == 0 else {
            throw DictionaryStoreError.prepareFailed(returnCode: returnCode)
        }
        try smokeQuery(stagedDic, ffi: ffi)

        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: stagedDic, to: destination)
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
        guard let json = String(validatingUTF8: jsonPointer),
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
}
