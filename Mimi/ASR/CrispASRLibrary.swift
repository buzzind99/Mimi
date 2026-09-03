import Foundation

/// VAD tuning knobs passed through to `crispasr_vad_slices`.
struct CrispASRVADParameters {
    let sampleRate: Int
    let threshold: Float
    let minSpeechMS: Int
    let minSilenceMS: Int
    let padMS: Int
}

/// The library surface `CrispASREngine` drives. Exposed as a protocol so
/// tests can inject a scripted fake without dlopen — the real class keeps
/// the process-global dlopen cache behind `open()`, which stays the engine
/// init's default (`library: nil`).
protocol CrispASRLibraryAPI: AnyObject {
    /// Absolute path of the bundled FireRedVAD model, or nil.
    var vadModelPath: String? { get }
    func setGpuBackend(_ name: String)
    func openSession(modelPath: String, backend: String) -> OpaquePointer?
    func closeSession(_ session: OpaquePointer?)
    func transcribeText(
        session: OpaquePointer?, pcm: borrowing Span<Float>, languageCode: String
    ) -> String?
    func vadSlices(
        modelPath: String,
        pcm: borrowing Span<Float>,
        parameters: CrispASRVADParameters
    ) -> (count: Int32, spans: UnsafeMutablePointer<Float>?)?
    func vadFree(_ spans: UnsafeMutablePointer<Float>?)
}

extension CrispASRLibrary: CrispASRLibraryAPI {}

/// Process-wide dlopen/dlsym binding of `libcrispasr.dylib` (stable C session
/// ABI). The dylib is optional at build time: the app builds and launches
/// before the native runtime is installed, and `ASREngineError.runtimeNotFound`
/// surfaces a clear message when it is missing. Typed methods shield the
/// engine from the raw C ABI.
final class CrispASRLibrary {
    private typealias FnSetGpuBackend = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias FnOpenExplicit = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32
    ) -> OpaquePointer?
    private typealias FnSessionClose = @convention(c) (OpaquePointer?) -> Void
    private typealias FnTranscribeLang = @convention(c) (
        OpaquePointer?, UnsafePointer<Float>?, Int32, UnsafePointer<CChar>?
    ) -> OpaquePointer?
    private typealias FnResultNSegments = @convention(c) (OpaquePointer?) -> Int32
    private typealias FnResultSegmentText = @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?
    private typealias FnResultFree = @convention(c) (OpaquePointer?) -> Void
    /// `crispasr_vad_slices`: returns the slice count (≥ 0), or negative on
    /// error (-1 bad args, -2 alloc failed, -3 model could not be loaded).
    /// Spans are malloc'd float pairs [start_s, end_s] relative to the input
    /// PCM, freed with `crispasr_vad_free`.
    private typealias FnVadSlices = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<Float>?, Int32, Int32,
        Float, Int32, Int32, Int32, Float, Int32,
        UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
    ) -> Int32
    private typealias FnVadFree = @convention(c) (UnsafeMutablePointer<Float>?) -> Void

    /// `n_threads` for `crispasr_session_open_explicit` — see the vendored
    /// ABI header `Mimi/native/include/crispasr/crispasr_session.h`.
    private static let sessionThreads: Int32 = 4

    private var fnSetGpuBackend: FnSetGpuBackend!
    private var fnOpenExplicit: FnOpenExplicit!
    private var fnSessionClose: FnSessionClose!
    private var fnTranscribeLang: FnTranscribeLang!
    private var fnResultNSegments: FnResultNSegments!
    private var fnResultSegmentText: FnResultSegmentText!
    private var fnResultFree: FnResultFree!
    private var fnVadSlices: FnVadSlices?
    private var fnVadFree: FnVadFree?
    /// Directory containing the loaded libcrispasr.dylib (from `dladdr`).
    /// Companion files (the VAD model) live next to it in every layout.
    private var dylibDirectory: String?

    /// Process-global dlopen cache: the dylib is opened once per process, so
    /// re-creating engines (warm restarts, model swaps) never re-opens it.
    /// dlopen is refcounted internally — the handle stays valid forever.
    /// `nonisolated(unsafe)`: the handle is process-immutable after this
    /// one-time initialization and dlopen is internally refcounted.
    private nonisolated(unsafe) static let library: Result<UnsafeMutableRawPointer, ASREngineError> = {
        do { return try .success(openLibrary()) } catch let error as ASREngineError {
            return .failure(error)
        } catch {
            return .failure(.runtimeNotFound(error.localizedDescription))
        }
    }()

    /// Binds the C symbols; throws when the dylib cannot be loaded.
    static func open() throws -> CrispASRLibrary {
        let handle: UnsafeMutableRawPointer
        switch library {
        case let .success(h): handle = h
        case let .failure(error): throw error
        }
        return CrispASRLibrary(handle: handle)
    }

    private init(handle: UnsafeMutableRawPointer) {
        bind(from: handle)
    }

    // MARK: - Symbols

    /// True when the runtime carries the optional VAD dispatcher ABI.
    var hasVADSymbols: Bool {
        fnVadSlices != nil && fnVadFree != nil
    }

    /// Absolute path of the bundled FireRedVAD model, or nil. Resolution
    /// order: env override, next to libcrispasr.dylib (covers both the dev
    /// checkout — where RPATH resolves the dylib but cwd/Bundle.main don't
    /// locate the model — and the bundled app), bundle Frameworks, cwd
    /// fallback.
    var vadModelPath: String? {
        guard hasVADSymbols else { return nil }
        let vadModelFile = "firered-vad.gguf"
        #if DEBUG
            if let env = ProcessInfo.processInfo.environment["MIMI_VAD_MODEL"], !env.isEmpty {
                return FileManager.default.fileExists(atPath: env) ? env : nil
            }
        #endif
        var candidates: [String?] = [
            dylibDirectory.map { $0 + "/\(vadModelFile)" },
            Bundle.main.privateFrameworksPath.map { $0 + "/crispasr/\(vadModelFile)" }
        ]
        #if DEBUG
            candidates.append(FileManager.default.currentDirectoryPath
                + "/local/frameworks/crispasr/\(vadModelFile)")
        #endif
        for path in candidates.compactMap({ $0 })
            where FileManager.default.fileExists(atPath: path)
        {
            return path
        }
        return nil
    }

    func setGpuBackend(_ name: String) {
        fnSetGpuBackend(name)
    }

    func openSession(modelPath: String, backend: String) -> OpaquePointer? {
        let pathStorage = modelPath.utf8CString
        let backendStorage = backend.utf8CString
        return pathStorage.withUnsafeBufferPointer { path in
            backendStorage.withUnsafeBufferPointer { backend in
                fnOpenExplicit(path.baseAddress, backend.baseAddress, Self.sessionThreads)
            }
        }
    }

    func closeSession(_ session: OpaquePointer?) {
        fnSessionClose(session)
    }

    /// Decodes `pcm` on the session and returns the concatenated segment
    /// text (untrimmed), or nil when the C call failed.
    func transcribeText(
        session: OpaquePointer?, pcm: borrowing Span<Float>, languageCode: String
    ) -> String? {
        let result = pcm.withUnsafeBufferPointer { buf -> OpaquePointer? in
            languageCode.withCString { lang in
                fnTranscribeLang(session, buf.baseAddress, Int32(buf.count), lang)
            }
        }
        guard let result else { return nil }
        defer { fnResultFree(result) }
        var text = ""
        let n = fnResultNSegments(result)
        for i in 0 ..< max(0, n) {
            if let seg = fnResultSegmentText(result, i) {
                text += String(cString: seg)
            }
        }
        return text
    }

    /// Runs `crispasr_vad_slices` over `pcm`; returns the slice count and the
    /// malloc'd span pairs (free with `vadFree`), or nil on C failure.
    func vadSlices(
        modelPath: String,
        pcm: borrowing Span<Float>,
        parameters: CrispASRVADParameters
    ) -> (count: Int32, spans: UnsafeMutablePointer<Float>?)? {
        guard let fnVadSlices else { return nil }
        var spansPtr: UnsafeMutablePointer<Float>?
        let count = pcm.withUnsafeBufferPointer { buf -> Int32 in
            modelPath.withCString { path in
                fnVadSlices(
                    path, buf.baseAddress, Int32(buf.count), Int32(parameters.sampleRate),
                    parameters.threshold, Int32(parameters.minSpeechMS),
                    Int32(parameters.minSilenceMS), Int32(parameters.padMS), 0, 0, &spansPtr
                )
            }
        }
        return (count, spansPtr)
    }

    func vadFree(_ spans: UnsafeMutablePointer<Float>?) {
        fnVadFree?(spans)
    }

    // MARK: - Library binding

    private static let dylibCandidates: [String?] = {
        var candidates: [String?] = []
        #if DEBUG
            // Test/CI override (absolute path) — release builds resolve only
            // via bundle/LC_RPATH paths, never the environment or the CWD.
            candidates.append(ProcessInfo.processInfo.environment["MIMI_ASR_DYLIB"])
        #endif
        // Bare name: resolved via the app's LC_RPATH (covers the dev
        // checkout via $(SRCROOT)/local/frameworks and the bundle via
        // @executable_path/../Frameworks).
        candidates.append("libcrispasr.dylib")
        candidates.append(Bundle.main.privateFrameworksPath.map { $0 + "/libcrispasr.dylib" })
        candidates.append(Bundle.main.path(forResource: "libcrispasr", ofType: "dylib"))
        candidates.append(Bundle.main.path(
            forResource: "libcrispasr", ofType: "dylib", inDirectory: "Frameworks"
        ))
        #if DEBUG
            // Development fallback (repo checkout before bundling).
            candidates.append(FileManager.default.currentDirectoryPath
                + "/local/frameworks/crispasr/libcrispasr.dylib")
        #endif
        return candidates
    }()

    private static func openLibrary() throws -> UnsafeMutableRawPointer {
        var lastError = "no candidate paths"
        for candidate in dylibCandidates {
            guard let path = candidate else { continue }
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                return handle
            }
            if let err = dlerror() {
                lastError = String(cString: err)
            }
        }
        throw ASREngineError.runtimeNotFound(lastError)
    }

    private func bind(from handle: UnsafeMutableRawPointer) {
        func fn<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        fnSetGpuBackend = fn("crispasr_set_gpu_backend", FnSetGpuBackend.self)
        fnOpenExplicit = fn("crispasr_session_open_explicit", FnOpenExplicit.self)
        fnSessionClose = fn("crispasr_session_close", FnSessionClose.self)
        fnTranscribeLang = fn("crispasr_session_transcribe_lang", FnTranscribeLang.self)
        fnResultNSegments = fn("crispasr_session_result_n_segments", FnResultNSegments.self)
        fnResultSegmentText = fn("crispasr_session_result_segment_text", FnResultSegmentText.self)
        fnResultFree = fn("crispasr_session_result_free", FnResultFree.self)
        // Optional: a runtime older than the VAD dispatcher degrades to
        // cap-only finalization instead of failing to launch.
        fnVadSlices = fn("crispasr_vad_slices", FnVadSlices.self)
        fnVadFree = fn("crispasr_vad_free", FnVadFree.self)

        guard fnSetGpuBackend != nil, fnOpenExplicit != nil, fnSessionClose != nil,
              fnTranscribeLang != nil, fnResultNSegments != nil, fnResultSegmentText != nil,
              fnResultFree != nil
        else {
            preconditionFailure("libcrispasr: missing required symbols")
        }

        // The function pointer lives inside the dylib, so dladdr recovers
        // its on-disk path regardless of which candidate loaded it.
        var info = Dl_info()
        let addr = UnsafeRawPointer(unsafeBitCast(fnSetGpuBackend, to: UnsafeRawPointer.self))
        if dladdr(addr, &info) != 0, let cPath = info.dli_fname {
            dylibDirectory = (String(cString: cPath) as NSString).deletingLastPathComponent
        }
    }
}
