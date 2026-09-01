import Foundation

/// Raw C ABI of the staged dictionary runtime (`libdictionary.dylib`), bound
/// with dlopen/dlsym — the same integration pattern as `CrispASREngine`. The
/// runtime exports exactly five generic `dictionary_*` symbols; the string
/// literals below must match that ABI exactly. The C surface is owned by our
/// FFI crate (`vendor/vibrato-ffi`), so the engine behind the dylib can be
/// swapped without touching this file.
///
/// All loading is injectable (`load(openLibrary:symbol:)`) so tests can drive
/// every failure path without the dylib. Fail-soft: `load` returns nil when
/// the library or any required symbol is missing; callers degrade to plain
/// text rather than crash.
struct DictionaryFFI {
    typealias FnOpen = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias FnFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FnTokenizeJSON = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>
    ) -> UnsafeMutablePointer<CChar>?
    typealias FnFreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    typealias FnPrepare = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<CChar>
    ) -> Int32

    /// Open a decompressed dictionary; null handle on failure.
    let open: FnOpen
    /// Free a handle returned by `open` (null is a no-op).
    let free: FnFree
    /// Tokenize text into a JSON string owned by the runtime; null on error.
    let tokenizeJSON: FnTokenizeJSON
    /// Free a string returned by `tokenizeJSON` (null is a no-op).
    let freeString: FnFreeString
    /// Decompress a bundled `system.dic.zst` into a dictionary file.
    /// Returns 0 on success, 1 on failure.
    let prepare: FnPrepare

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
        guard let open = symbol(handle, "dictionary_open"),
              let free = symbol(handle, "dictionary_free"),
              let tokenizeJSON = symbol(handle, "dictionary_tokenize_json"),
              let freeString = symbol(handle, "dictionary_free_string"),
              let prepare = symbol(handle, "dictionary_prepare")
        else { return nil }
        return DictionaryFFI(
            open: unsafeBitCast(open, to: FnOpen.self),
            free: unsafeBitCast(free, to: FnFree.self),
            tokenizeJSON: unsafeBitCast(tokenizeJSON, to: FnTokenizeJSON.self),
            freeString: unsafeBitCast(freeString, to: FnFreeString.self),
            prepare: unsafeBitCast(prepare, to: FnPrepare.self)
        )
    }
}
