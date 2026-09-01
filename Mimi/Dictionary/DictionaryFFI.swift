import Foundation

/// Raw C ABI of the staged dictionary runtime (`libdictionary.dylib`), bound
/// with dlopen/dlsym — the same integration pattern as `CrispASREngine`. The
/// exported symbols keep the vendored tokenizer's upstream `tentoku_` prefix,
/// so the string literals below are the sanctioned upstream-name occurrence
/// outside `vendor/`: they must match the dylib's exported ABI exactly.
///
/// All loading is injectable (`load(openLibrary:symbol:)`) so tests can drive
/// every failure path without the dylib. Fail-soft: `load` returns nil when
/// the library or any required symbol is missing; callers degrade to plain
/// text rather than crash.
struct DictionaryFFI {
    typealias FnBuildDB = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<CChar>
    ) -> Int32
    typealias FnOpen = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias FnFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FnTokenizeJSON = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>, UInt32
    ) -> UnsafeMutablePointer<CChar>?
    typealias FnLookupJSON = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>, UInt32
    ) -> UnsafeMutablePointer<CChar>?
    typealias FnFreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    /// Build a JMdict SQLite database from a local JMdict_e.gz file.
    /// Returns 0 on success, 1 on failure.
    let buildDB: FnBuildDB
    /// Open a built database; null handle on failure.
    let open: FnOpen
    /// Free a handle returned by `open` (null is a no-op).
    let free: FnFree
    /// Tokenize text into a JSON string owned by the runtime; null on error.
    let tokenizeJSON: FnTokenizeJSON
    /// Look up a word as JSON entries owned by the runtime; null when nothing
    /// matches (reserved for future word-lookup UI; the annotator never calls it).
    let lookupJSON: FnLookupJSON
    /// Free a string returned by a `*JSON` function (null is a no-op).
    let freeString: FnFreeString

    // MARK: - Loading

    /// Search paths for the staged dylib, tried in order. The bare name
    /// resolves via the app's LC_RPATH (dev checkout: $(SRCROOT)/local/
    /// frameworks; bundled app: @executable_path/../Frameworks).
    private static let dylibCandidates: [String?] = {
        var candidates: [String?] = [
            "libdictionary.dylib",
            Bundle.main.privateFrameworksPath.map { $0 + "/libdictionary.dylib" },
            Bundle.main.path(forResource: "libdictionary", ofType: "dylib"),
            Bundle.main.path(
                forResource: "libdictionary", ofType: "dylib", inDirectory: "Frameworks"
            )
        ]
        // Development fallback (repo checkout before bundling). Debug-only so
        // release never depends on the working directory.
        #if DEBUG
            candidates.append(
                FileManager.default.currentDirectoryPath + "/local/frameworks/libdictionary.dylib"
            )
        #endif
        return candidates
    }()

    /// Binds all required symbols from the first loadable candidate, or nil.
    /// Defaults are the real dlopen/dlsym; tests inject fakes to exercise
    /// candidate fallback and missing-symbol failures.
    static func load(
        openLibrary: (String) -> UnsafeMutableRawPointer? = { dlopen($0, RTLD_NOW | RTLD_LOCAL) },
        symbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { dlsym($0, $1) }
    ) -> DictionaryFFI? {
        var handle: UnsafeMutableRawPointer?
        for candidate in dylibCandidates {
            guard let path = candidate else { continue }
            if let loaded = openLibrary(path) {
                handle = loaded
                break
            }
        }
        guard let handle else { return nil }
        guard let buildDB = symbol(handle, "tentoku_build_db"),
              let open = symbol(handle, "tentoku_open"),
              let free = symbol(handle, "tentoku_free"),
              let tokenizeJSON = symbol(handle, "tentoku_tokenize_json"),
              let lookupJSON = symbol(handle, "tentoku_lookup_json"),
              let freeString = symbol(handle, "tentoku_free_string")
        else { return nil }
        return DictionaryFFI(
            buildDB: unsafeBitCast(buildDB, to: FnBuildDB.self),
            open: unsafeBitCast(open, to: FnOpen.self),
            free: unsafeBitCast(free, to: FnFree.self),
            tokenizeJSON: unsafeBitCast(tokenizeJSON, to: FnTokenizeJSON.self),
            lookupJSON: unsafeBitCast(lookupJSON, to: FnLookupJSON.self),
            freeString: unsafeBitCast(freeString, to: FnFreeString.self)
        )
    }
}
