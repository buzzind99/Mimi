import Foundation

/// Swift wrapper over `libcrispasr.dylib` (stable C session ABI, bound at
/// runtime with dlopen/dlsym so the app builds and launches before the native
/// runtime is installed).
///
/// Runs the Qwen3-ASR backend (`qwen3`), which has no cache-aware streaming —
/// the sliding window lives here instead of in the C library:
///
///   - `push` appends 160 ms chunks to a rolling utterance buffer (bounded by
///     a forced-final cap) plus a 10 s window used for partial decodes.
///   - FireRedVAD (via `crispasr_vad_slices`) runs on a dedicated VAD queue
///     every 500 ms and is the authoritative speech signal: it separates
///     speech from BGM, gates partial decodes, and finalizes an utterance
///     once it has confirmed `endpointSamples` of silence after the last
///     speech span. Buffers the VAD finds speechless are discarded without
///     decoding.
///   - A cheap per-chunk RMS check (`utteranceHasLoudAudio`) is only a
///     backstop so truly silent audio is never decoded — including in
///     degraded mode (VAD model unavailable: cap-only finals, no partials).
///   - A `step`-spaced window decode posts `.partial` events (HUD draft text);
///     the endpoint redecodes the buffered utterance PCM (CrispASR's
///     "redecode" final mode) and posts one clean `.final`.
///
/// Threading: pushes land on the caller's audio thread but only take the
/// state lock; actual decoding runs on a dedicated serial queue so the main
/// thread's 60 ms `poll()` loop never blocks behind a multi-second decode.
/// VAD analysis runs on its own serial queue: a qwen3 decode takes seconds,
/// and endpointing must never wait behind one (a starved VAD freezes both
/// the partial gate and silence detection). The two job types interlock
/// only through the state lock; the C library serializes VAD access to the
/// cached model internally.
final class CrispASREngine: ASREngine {
    let isMock = false

    /// Called on an arbitrary thread when a decode fails. Throttled by the
    /// engine to the first failure and then once every 32 consecutive ones.
    var onEngineError: ((String) -> Void)?

    private let modelPath: String
    private let languageCode: String

    // Window/endpointing knobs (mirrors the CLI defaults where sensible).
    private static let sampleRate = 16000
    private static let stepSamples = 1 * sampleRate // decode cadence
    private static let lengthSamples = 10 * sampleRate // rolling window cap
    /// How much confirmed silence after the last VAD speech span triggers a
    /// final. Must stay ≥ the VAD's `min_silence_ms` (below) — that is what
    /// makes a span end + this much analyzed audio a *confirmed* silence gap.
    private static let endpointSamples = 800 * sampleRate / 1000
    /// Forced-final cap: safety net under VAD, and the only endpoint when the
    /// VAD model is unavailable (degraded mode).
    private static let utteranceCapSamples = 12 * sampleRate
    /// Tail kept in the rolling window after a final, for decode context.
    private static let windowKeepTailSamples = 200 * sampleRate / 1000
    private static let minDecodeSamples = 2 * sampleRate // encoder conv-kernel floor
    /// Backstop only (never used for endpointing): marks a buffer as not
    /// truly silent so the cap path never decodes known-silent audio.
    private static let speechRMS: Float = 1e-3
    /// Total budget for `finish()` to wait out in-flight decode/VAD jobs.
    /// Bounds the whole drain, not each semaphore wait — a hung C call never
    /// clears its in-flight flag, so per-wait timeouts alone would re-arm
    /// forever. (The synchronous flush decode below stays unbounded: it is a
    /// single direct C call on the session, and aborting mid-call would leave
    /// the C library using a session this side has already torn down.)
    private static let drainTimeout: TimeInterval = 30

    // FireRedVAD (via the dispatcher-backed crispasr_vad_slices ABI; the
    // model is process-cached in the C library after the first call).
    private static let vadModelFile = "firered-vad.gguf"
    private static let vadCheckIntervalSamples = 500 * sampleRate / 1000
    private static let vadThreshold: Float = 0.5
    private static let vadMinSpeechMS = 250
    /// Must equal `endpointSamples` — see the comment there.
    private static let vadMinSilenceMS = 600
    private static let vadPadMS = 30
    /// Don't discard a short speechless buffer on a single VAD pass — onsets
    /// can be missed on very short windows; wait until the buffer is at
    /// least this long before trusting a zero-span verdict.
    private static let vadMinDiscardSamples = 2 * sampleRate

    // MARK: - Bound C functions

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

    init(modelPath: URL, languageCode: String = "ja") throws {
        self.modelPath = modelPath.path
        self.languageCode = languageCode
        let handle: UnsafeMutableRawPointer
        switch Self.library {
        case let .success(h): handle = h
        case let .failure(error): throw error
        }
        bind(from: handle)
        if fnVadSlices != nil, fnVadFree != nil,
           let vad = Self.resolveVADModelPath(nearDylib: dylibDirectory)
        {
            vadModelPath = vad
        } else {
            vadModelPath = nil
            vadUnavailableReason =
                "VAD unavailable (missing firered-vad.gguf or libcrispasr VAD symbols) — " +
                "finalization falls back to the \(Self.utteranceCapSamples / Self.sampleRate)s cap"
        }
    }

    /// Absolute path of the bundled FireRedVAD model, or nil. Resolution
    /// order: env override, next to libcrispasr.dylib (covers both the dev
    /// checkout — where RPATH resolves the dylib but cwd/Bundle.main don't
    /// locate the model — and the bundled app), bundle Frameworks, cwd
    /// fallback.
    private static func resolveVADModelPath(nearDylib dylibDir: String?) -> String? {
        #if DEBUG
            if let env = ProcessInfo.processInfo.environment["MIMI_VAD_MODEL"], !env.isEmpty {
                return FileManager.default.fileExists(atPath: env) ? env : nil
            }
        #endif
        var candidates: [String?] = [
            dylibDir.map { $0 + "/\(vadModelFile)" },
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

    /// Process-global dlopen cache: the dylib is opened once per process, so
    /// re-creating engines (warm restarts, model swaps) never re-opens it.
    /// dlopen is refcounted internally — the handle stays valid forever.
    private static let library: Result<UnsafeMutableRawPointer, ASREngineError> = {
        do { return try .success(openLibrary()) } catch let error as ASREngineError {
            return .failure(error)
        } catch {
            return .failure(.runtimeNotFound(error.localizedDescription))
        }
    }()

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

    // MARK: - State

    private let lock = NSLock()
    /// Serializes `prepare` so a background warm-up and a session start can
    /// never both open a C session (the second opener would leak the first).
    private let prepareLock = NSLock()
    private let decodeQueue = DispatchQueue(label: "dev.mimi.asr.decode", qos: .userInitiated)
    private let vadQueue = DispatchQueue(label: "dev.mimi.asr.vad", qos: .userInitiated)
    /// Signaled after every decode or VAD completion so `finish` can wait
    /// out in-flight work. Never waited on by the job paths themselves.
    private let jobFinished = DispatchSemaphore(value: 0)

    private var session: OpaquePointer?

    private var totalSamples = 0
    private var window: [Float] = [] // last `lengthSamples` samples
    private var utterance: [Float] = [] // PCM since the last final
    private var utteranceStartSample = 0
    /// Bumped on every final/discard so stale VAD results (snapshot taken
    /// before the reset) can be ignored.
    private var utteranceGeneration = 0
    private var lastDecodeDispatchSample = 0
    /// `vadLastSpeechEndSample` at the time the last partial was dispatched.
    /// Partials only re-decode when the VAD has confirmed speech beyond this,
    /// so a pause doesn't chain identical window redecodes (which would both
    /// freeze the HUD draft and starve the VAD on the serial decode queue).
    private var lastPartialSpeechEndSample = 0
    private var processedCount = 0
    private var decodeInFlight = false
    private var vadInFlight = false
    private var finishing = false
    private var inbox: [ASREvent] = []
    private var consecutiveDecodeFailures = 0

    /// VAD state (all guarded by `lock`).
    private var vadModelPath: String?
    /// Set in init when the VAD can't be used; reported once in `prepare`.
    private var vadUnavailableReason: String?
    private var vadUnavailableReported = false
    /// Flipped off at runtime on VAD failure → degraded mode for the session.
    private var vadEnabled = true
    private var consecutiveVADFailures = 0
    private var lastVADDispatchSample = 0
    /// True once the VAD has found a speech span in the current utterance.
    private var utteranceHasSpeech = false
    /// RMS backstop: any chunk since the last final/discard was not silent.
    private var utteranceHasLoudAudio = false
    /// Absolute sample of the end of the last VAD speech span (nil = none yet).
    private var vadLastSpeechEndSample: Int?
    /// Absolute sample through which VAD results are valid for the current
    /// utterance (0 = nothing analyzed). Endpointing only trusts a span end
    /// once analysis has progressed past it.
    private var vadAnalyzedThroughSample = 0
    /// Absolute sample of the start of the first speech span in the utterance.
    private var vadFirstSpeechStartSample: Int?

    var processedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return processedCount
    }

    // MARK: - ASREngine

    func prepare() throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ASREngineError.modelNotFound(modelPath)
        }
        prepareLock.lock()
        defer { prepareLock.unlock() }
        // Warm restart: the C session from a previous run is still open —
        // reuse it and skip the multi-second GGUF load + Metal compile.
        lock.lock()
        let alreadyOpen = session != nil
        lock.unlock()
        if alreadyOpen {
            #if DEBUG
                print("[asr] prepare: reusing warm session (model already loaded)")
            #endif
            return
        }
        // TLS-backed GPU preference: must be set on the same thread that
        // opens the session (prepare runs once, before any decode starts).
        #if DEBUG
            print("[asr] prepare: opening C session (qwen3/metal)")
        #endif
        fnSetGpuBackend("metal")
        let pathStorage = modelPath.utf8CString
        let langStorage = "qwen3".utf8CString
        let handle = pathStorage.withUnsafeBufferPointer { path in
            langStorage.withUnsafeBufferPointer { backend in
                fnOpenExplicit(path.baseAddress, backend.baseAddress, 4)
            }
        }
        guard let handle else {
            throw ASREngineError.createFailed("crispasr_session_open_explicit failed (backend qwen3)")
        }
        session = handle
        if let reason = vadUnavailableReason, !vadUnavailableReported {
            vadUnavailableReported = true
            #if DEBUG
                print("[asr] \(reason)")
            #endif
            onEngineError?(reason)
        }
    }

    func openStream() throws {
        lock.lock(); defer { lock.unlock() }
        totalSamples = 0
        window = []
        utterance = []
        utteranceStartSample = 0
        utteranceGeneration += 1
        lastDecodeDispatchSample = 0
        lastPartialSpeechEndSample = 0
        processedCount = 0
        decodeInFlight = false
        vadInFlight = false
        finishing = false
        inbox = []
        lastVADDispatchSample = 0
        utteranceHasSpeech = false
        utteranceHasLoudAudio = false
        vadLastSpeechEndSample = nil
        vadAnalyzedThroughSample = 0
        vadFirstSpeechStartSample = nil
        consecutiveDecodeFailures = 0
        consecutiveVADFailures = 0
        vadEnabled = true
    }

    func push(_ samples: [Float]) {
        lock.lock()
        guard session != nil, !finishing else {
            lock.unlock()
            return
        }
        window.append(contentsOf: samples)
        if window.count > Self.lengthSamples {
            window.removeFirst(window.count - Self.lengthSamples)
        }
        totalSamples += samples.count

        // Every chunk feeds the utterance (bounded by the forced-final cap);
        // speech vs. silence is the VAD's call, not an energy threshold's.
        if utterance.isEmpty {
            utteranceStartSample = totalSamples - samples.count
        }
        utterance.append(contentsOf: samples)

        // RMS backstop: track whether this buffer is not truly silent.
        var energy: Float = 0
        for s in samples {
            energy += s * s
        }
        let rms = (energy / Float(max(1, samples.count))).squareRoot()
        if rms > Self.speechRMS {
            utteranceHasLoudAudio = true
        }

        maybeScheduleWorkLocked()
        lock.unlock()
    }

    /// Caller holds `lock`. Dispatches any due VAD pass (on its own queue)
    /// plus at most one decode job: an endpoint (final) decode first, else a
    /// step-spaced window (partial) decode. VAD and decode jobs run
    /// concurrently — the VAD is what feeds the endpoint and partial gates,
    /// so it must keep flowing while a multi-second decode occupies the
    /// decode queue.
    private func maybeScheduleWorkLocked() {
        guard session != nil, !finishing else { return }
        maybeScheduleVADLocked()
        if maybeScheduleFinalLocked() {
            return
        }
        maybeSchedulePartialLocked()
    }

    /// Caller holds `lock`. Returns true if an endpoint (final) decode or a
    /// discard was dispatched.
    @discardableResult
    private func maybeScheduleFinalLocked() -> Bool {
        guard session != nil, !finishing, !decodeInFlight, !utterance.isEmpty else { return false }

        // Silence endpoint: the VAD confirmed a ≥`vadMinSilenceMS` gap by
        // ending the last speech span, and has analyzed at least
        // `endpointSamples` of audio past it (so a lagging VAD pass can't
        // finalize mid-speech). The endpoint redecodes the whole utterance
        // span for a clean final.
        if let speechEnd = vadLastSpeechEndSample,
           vadAnalyzedThroughSample - speechEnd >= Self.endpointSamples
        {
            #if DEBUG
                print(String(
                    format: "[asr] endpoint: %.2fs of confirmed silence after speech",
                    Double(vadAnalyzedThroughSample - speechEnd) / Double(Self.sampleRate)
                ))
            #endif
            dispatchFinalLocked(end: speechEnd)
            return true
        }

        // Forced-final cap: safety net under VAD, and the only endpoint in
        // degraded mode. Never decodes a buffer the backstop knows is silent.
        if utterance.count >= Self.utteranceCapSamples {
            if utteranceHasLoudAudio || utteranceHasSpeech {
                #if DEBUG
                    print("[asr] endpoint: utterance cap reached")
                #endif
                dispatchFinalLocked(end: utteranceStartSample + utterance.count)
            } else {
                #if DEBUG
                    print("[asr] discard: silent utterance reached cap")
                #endif
                discardUtteranceLocked()
            }
            return true
        }
        return false
    }

    /// True when the VAD is actually in the loop (symbols bound, model
    /// present, not runtime-disabled). Everything else is degraded mode.
    /// Callers hold `lock`.
    private var vadActive: Bool {
        vadEnabled && vadModelPath != nil
    }

    /// Caller holds `lock`. Re-runs the VAD over the utterance after
    /// `vadCheckIntervalSamples` of new audio. Returns true if dispatched.
    @discardableResult
    private func maybeScheduleVADLocked() -> Bool {
        guard vadActive, !vadInFlight, !utterance.isEmpty,
              totalSamples - lastVADDispatchSample >= Self.vadCheckIntervalSamples
        else { return false }
        lastVADDispatchSample = totalSamples
        let pcm = utterance
        let start = utteranceStartSample
        let generation = utteranceGeneration
        vadInFlight = true
        vadQueue.async { [weak self] in
            self?.runVADJob(pcm: pcm, utteranceStart: start, generation: generation)
        }
        return true
    }

    /// Caller holds `lock`. Dispatches the step-spaced partial decode, gated
    /// on VAD-confirmed speech (BGM-only stretches must not put hallucinated
    /// drafts on the HUD) and on the VAD having found new speech since the
    /// last partial — a pause must not re-decode an unchanged window (which
    /// would just freeze the HUD draft on identical text).
    private func maybeSchedulePartialLocked() {
        guard session != nil, !finishing, !decodeInFlight, !utterance.isEmpty,
              utteranceHasSpeech,
              (vadLastSpeechEndSample ?? 0) > lastPartialSpeechEndSample,
              totalSamples - lastDecodeDispatchSample >= Self.stepSamples
        else { return }
        let pcm = window
        let end = totalSamples
        lastPartialSpeechEndSample = vadLastSpeechEndSample ?? 0
        decodeInFlight = true
        decodeQueue.async { [weak self] in
            self?.runDecode(pcm: pcm, start: max(0, end - pcm.count), end: end, isFinal: false)
        }
        lastDecodeDispatchSample = totalSamples
    }

    private func dispatchFinalLocked(end: Int) {
        let pcm = utterance
        let start = vadFirstSpeechStartSample ?? utteranceStartSample
        #if DEBUG
            print(String(
                format: "[asr] final dispatch: %.2fs utterance [%.2fs..%.2fs]",
                Double(pcm.count) / Double(Self.sampleRate),
                Double(start) / Double(Self.sampleRate),
                Double(end) / Double(Self.sampleRate)
            ))
        #endif
        decodeInFlight = true
        decodeQueue.async { [weak self] in
            self?.runDecode(pcm: pcm, start: start, end: end, isFinal: true)
        }
    }

    /// Runs on `vadQueue`. One job at a time (guarded by `vadInFlight` and
    /// the serial queue). Updates speech state under `lock`; the
    /// `crispasr_vad_slices` call itself is lock-free (the C library
    /// serializes access to the cached model internally).
    private func runVADJob(pcm: [Float], utteranceStart: Int, generation: Int) {
        defer {
            lock.lock()
            vadInFlight = false
            // The VAD verdict may make an endpoint (or a decode step) due.
            maybeScheduleWorkLocked()
            lock.unlock()
            // Signal *after* the flag reset (semaphore counts, so a waiter
            // that checked the flag before this point still wakes): the old
            // order let `finish` miss the signal and stall for its full
            // 30 s timeout.
            jobFinished.signal()
        }
        guard let vadModelPath, let fnVadSlices, let fnVadFree else { return }

        var spansPtr: UnsafeMutablePointer<Float>?
        #if DEBUG
            let vadStart = ContinuousClock.now
        #endif
        let count = pcm.withUnsafeBufferPointer { buf -> Int32 in
            vadModelPath.withCString { path in
                fnVadSlices(
                    path, buf.baseAddress, Int32(pcm.count), Int32(Self.sampleRate),
                    Self.vadThreshold, Int32(Self.vadMinSpeechMS), Int32(Self.vadMinSilenceMS),
                    Int32(Self.vadPadMS), 0, 0, &spansPtr
                )
            }
        }
        #if DEBUG
            print("[asr] vad: \(pcm.count) samples -> \(count) spans in \(ContinuousClock.now - vadStart)")
        #endif
        guard count >= 0 else {
            handleVADFailure(code: count)
            return
        }

        lock.lock()
        defer { lock.unlock() }
        // A final/discard reset the utterance while this pass was running —
        // the result no longer matches live state.
        guard generation == utteranceGeneration, vadEnabled else {
            #if DEBUG
                print("[asr] vad: dropped stale result (generation \(generation) vs \(utteranceGeneration), vadEnabled=\(vadEnabled))")
            #endif
            return
        }
        vadAnalyzedThroughSample = utteranceStart + pcm.count

        if count == 0 || spansPtr == nil {
            // Speechless buffer (VAD is authoritative over BGM): drop it so
            // the forced-final cap can't decode speechless audio later.
            if pcm.count >= Self.vadMinDiscardSamples {
                #if DEBUG
                    print(String(
                        format: "[asr] vad: speechless buffer (%.2fs) — discarded",
                        Double(pcm.count) / Double(Self.sampleRate)
                    ))
                #endif
                discardUtteranceLocked()
            }
            return
        }
        guard let spansPtr else { return }
        defer { fnVadFree(spansPtr) }

        // Spans are float pairs [start_s, end_s] relative to the snapshot.
        // Every pass re-analyzes the whole utterance, so the latest pass's
        // last span end supersedes earlier ones. This matters during the
        // first `vadMinSilenceMS` of a pause: the VAD still reports the
        // open segment flushed at the analyzed-buffer end (firered closes a
        // span only after `min_silence_ms` of silence), which lies *inside*
        // the silence. Keeping a max() would ratchet speechEnd forward and
        // blind the endpoint until `speechEnd + endpointSamples` — merging
        // any sentence gap shorter than that. The closed span from the
        // confirming pass must therefore replace the flushed value.
        let firstStart = utteranceStart
            + Int(spansPtr.pointee * Float(Self.sampleRate))
        let lastEnd = utteranceStart
            + Int(spansPtr[2 * (Int(count) - 1) + 1] * Float(Self.sampleRate))
        vadFirstSpeechStartSample = vadFirstSpeechStartSample ?? firstStart
        vadLastSpeechEndSample = lastEnd
        utteranceHasSpeech = true
    }

    /// Caller holds `lock`. Drops the current utterance (speechless audio)
    /// and shrinks the window so stale audio can't leak into later decodes.
    private func discardUtteranceLocked() {
        utterance = []
        utteranceStartSample = 0
        utteranceGeneration += 1
        utteranceHasSpeech = false
        utteranceHasLoudAudio = false
        lastPartialSpeechEndSample = 0
        vadLastSpeechEndSample = nil
        vadAnalyzedThroughSample = 0
        vadFirstSpeechStartSample = nil
        trimWindowLocked(throughSample: totalSamples)
    }

    private func handleVADFailure(code: Int32) {
        lock.lock()
        consecutiveVADFailures += 1
        // -3 (model could not be loaded) is persistent — degrade immediately;
        // transient errors get a few retries first.
        let shouldDisable = code == -3 || consecutiveVADFailures >= 3
        let alreadyDisabled = !vadEnabled
        if shouldDisable {
            vadEnabled = false
        }
        let n = consecutiveVADFailures
        lock.unlock()

        if shouldDisable && !alreadyDisabled {
            let message = "VAD failed (\(code)) — falling back to cap-only finalization"
            #if DEBUG
                print("[asr] \(message)")
            #endif
            onEngineError?(message)
        } else if n == 1 || n % 32 == 0 {
            let message = "VAD pass failed (×\(n))"
            #if DEBUG
                print("[asr] \(message)")
            #endif
        }
    }

    /// Runs on `decodeQueue`. One decode at a time (guarded by `decodeInFlight`
    /// and the serial queue); posts results into the inbox under `lock`.
    private func runDecode(pcm: [Float], start: Int, end: Int, isFinal: Bool) {
        #if DEBUG
            let decodeStart = ContinuousClock.now
        #endif
        defer {
            lock.lock()
            decodeInFlight = false
            // A decode finishing may mean the next step (or a due VAD pass)
            // is already pending.
            maybeScheduleWorkLocked()
            lock.unlock()
            // Signal after the flag reset — see runVADJob.
            jobFinished.signal()
        }
        guard let session else { return }

        // Backends with convolutional encoders reject audio shorter than the
        // first conv kernel (~2 s at 16 kHz); zero-pad short spans.
        var pcm = pcm
        if pcm.count < Self.minDecodeSamples {
            pcm.append(contentsOf: [Float](repeating: 0, count: Self.minDecodeSamples - pcm.count))
        }

        let result = pcm.withUnsafeBufferPointer { buf -> OpaquePointer? in
            languageCode.withCString { lang in
                fnTranscribeLang(session, buf.baseAddress, Int32(pcm.count), lang)
            }
        }
        #if DEBUG
            print("[asr] \(isFinal ? "final" : "partial") decode: \(pcm.count) samples in \(ContinuousClock.now - decodeStart)")
        #endif
        guard let result else {
            reportDecodeFailure()
            return
        }
        defer { fnResultFree(result) }

        var text = ""
        let n = fnResultNSegments(result)
        for i in 0 ..< max(0, n) {
            if let seg = fnResultSegmentText(result, i) {
                text += String(cString: seg)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
            if text.isEmpty {
                print("[asr] \(isFinal ? "final" : "partial") decode returned no text (\(pcm.count) samples)")
            }
        #endif

        lock.lock()
        defer { lock.unlock() }
        processedCount = max(processedCount, end)
        if isFinal {
            if !text.isEmpty {
                inbox.append(.final(text: text, startSample: start, endSample: end, lang: languageCode))
            }
            // Close out the utterance even when the decode produced nothing:
            // leaving it open would keep the endpoint/cap conditions true and
            // re-decode the same buffer forever (finals wedge, partials die).
            finalizeUtteranceLocked(end: end)
        } else if !text.isEmpty {
            inbox.append(.partial(text: text))
        }
    }

    /// Caller holds `lock`. Closes out the utterance through `end` (the span
    /// a final decode covered): drops the finalized span, re-seeding any
    /// speech that resumed while the decode was in flight as the start of
    /// the next utterance, and resets all endpoint state.
    private func finalizeUtteranceLocked(end: Int) {
        let finalized = end - utteranceStartSample
        if finalized >= 0, finalized < utterance.count {
            utterance.removeFirst(finalized)
            utteranceStartSample = end
            if !utterance.isEmpty {
                utteranceHasLoudAudio = true
            }
        } else {
            utterance = []
            utteranceStartSample = 0
        }
        utteranceGeneration += 1
        utteranceHasSpeech = false
        lastPartialSpeechEndSample = 0
        vadLastSpeechEndSample = nil
        vadAnalyzedThroughSample = 0
        vadFirstSpeechStartSample = nil
        trimWindowLocked(throughSample: end)
    }

    /// Caller holds `lock`. Drops the finalized span from the rolling window
    /// (plus a short tail for decode context) so the next step-spaced partial
    /// decodes only post-final audio instead of re-transcribing the sentence
    /// that was just finalized.
    private func trimWindowLocked(throughSample end: Int) {
        let windowStart = totalSamples - window.count
        let drop = min(window.count, max(0, end + Self.windowKeepTailSamples - windowStart))
        if drop > 0 {
            window.removeFirst(drop)
        }
    }

    private func reportDecodeFailure() {
        lock.lock()
        consecutiveDecodeFailures += 1
        let n = consecutiveDecodeFailures
        lock.unlock()
        guard n == 1 || n % 32 == 0 else { return }
        let message = "ASR decode failed (×\(n))"
        #if DEBUG
            print("[asr] \(message)")
        #endif
        onEngineError?(message)
    }
}

// MARK: - Draining & teardown

extension CrispASREngine {
    func poll() -> ASREvent? {
        lock.lock(); defer { lock.unlock() }
        guard !inbox.isEmpty else { return nil }
        return inbox.removeFirst()
    }

    func finish() -> [ASREvent] {
        lock.lock()
        finishing = true
        lock.unlock()
        // Wait (bounded) for any in-flight decode or VAD pass to finish.
        // The deadline caps the TOTAL wait: each semaphore wait is at most
        // the remaining budget, so a hung decode/VAD call (its flag never
        // clears) delays teardown by at most `drainTimeout` instead of
        // re-arming a fresh 30 s wait forever.
        let deadline = Date().addingTimeInterval(Self.drainTimeout)
        while true {
            lock.lock()
            let inFlight = decodeInFlight || vadInFlight
            lock.unlock()
            if !inFlight {
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                break
            }
            _ = jobFinished.wait(timeout: .now() + remaining)
        }

        // Flush any open utterance synchronously — capture has already
        // stopped, so nothing new can arrive. Skip speechless buffers
        // (VAD-confirmed silence, or the RMS backstop in degraded mode).
        lock.lock()
        let pcm = utterance
        let start = vadFirstSpeechStartSample ?? utteranceStartSample
        let end = vadLastSpeechEndSample ?? (utteranceStartSample + utterance.count)
        let hadSpeech = utteranceHasSpeech || (!vadActive && utteranceHasLoudAudio)
        lock.unlock()

        if hadSpeech, session != nil {
            var padded = pcm
            if padded.count < Self.minDecodeSamples {
                padded.append(
                    contentsOf: [Float](repeating: 0, count: Self.minDecodeSamples - padded.count)
                )
            }
            let result = padded.withUnsafeBufferPointer { buf -> OpaquePointer? in
                languageCode.withCString { lang in
                    fnTranscribeLang(session, buf.baseAddress, Int32(padded.count), lang)
                }
            }
            if let result {
                defer { fnResultFree(result) }
                var text = ""
                let n = fnResultNSegments(result)
                for i in 0 ..< max(0, n) {
                    if let seg = fnResultSegmentText(result, i) {
                        text += String(cString: seg)
                    }
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                #if DEBUG
                    print("[asr] flush decode: \(padded.count) samples -> \(text.isEmpty ? "no text" : "\(text.count) chars")")
                #endif
                if !text.isEmpty {
                    inbox.append(.final(
                        text: text, startSample: start, endSample: end, lang: languageCode
                    ))
                }
            }
        }

        lock.lock()
        let drained = inbox
        inbox = []
        lock.unlock()
        return drained
    }

    /// Releases the C session (and the resident model) permanently. Not part
    /// of normal teardown — sessions stay warm so restarts are instant. Used
    /// only when the factory discards the engine (e.g. the model file was
    /// replaced and a fresh one takes its place).
    func close() {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        lock.lock()
        finishing = true
        let sessionHandle = session
        session = nil
        lock.unlock()
        if let sessionHandle {
            fnSessionClose(sessionHandle)
        }
    }
}
