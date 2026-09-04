import Foundation

/// Shared dlopen plumbing for the FFI runtimes (`CrispASRLibrary`,
/// `DictionaryFFI`): the standard staged-dylib candidate list and first-
/// successful-handle loading.
enum DylibLoader {
    /// Search paths for a staged dylib, tried in order: a debug-only
    /// environment override, the bare name (resolved via the app's LC_RPATH —
    /// dev checkout: `$(SRCROOT)/local/frameworks`; bundled app:
    /// `@executable_path/../Frameworks`), the bundle's private frameworks and
    /// resource locations, and a debug-only dev-checkout fallback so release
    /// never depends on the working directory.
    static func candidates(
        named name: String,
        debugEnvKey: String? = nil,
        debugFallbackSubdirectory: String? = nil
    ) -> [String?] {
        var candidates: [String?] = []
        #if DEBUG
            if let debugEnvKey {
                candidates.append(ProcessInfo.processInfo.environment[debugEnvKey])
            }
        #endif
        candidates.append(name)
        candidates.append(Bundle.main.privateFrameworksPath.map { $0 + "/" + name })
        candidates.append(Bundle.main.path(
            forResource: (name as NSString).deletingPathExtension,
            ofType: (name as NSString).pathExtension
        ))
        candidates.append(Bundle.main.path(
            forResource: (name as NSString).deletingPathExtension,
            ofType: (name as NSString).pathExtension,
            inDirectory: "Frameworks"
        ))
        #if DEBUG
            let fallback = "local/frameworks" + (debugFallbackSubdirectory.map { "/" + $0 } ?? "")
            candidates.append(FileManager.default.currentDirectoryPath + "/" + fallback + "/" + name)
        #endif
        return candidates
    }

    /// dlopens the first loadable candidate. `lastError` carries the most
    /// recent `dlerror()` message (only meaningful for the default `open`).
    static func open(
        candidates: [String?],
        open: (String) -> UnsafeMutableRawPointer? = { dlopen($0, RTLD_NOW | RTLD_LOCAL) }
    ) -> (handle: UnsafeMutableRawPointer?, lastError: String?) {
        var handle: UnsafeMutableRawPointer?
        var lastError: String?
        for candidate in candidates {
            guard let path = candidate else { continue }
            if let loaded = open(path) {
                handle = loaded
                break
            }
            if let err = dlerror() {
                lastError = String(cString: err)
            }
        }
        return (handle, lastError)
    }
}
