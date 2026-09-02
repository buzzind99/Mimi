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
///
/// Sendability: all shared state is `lock`/`prepareLock`-guarded, so the
/// engine is safe to hand across concurrency domains (e.g. `finish()` runs
/// detached from the main actor on session stop).
final class CrispASREngine: ASREngine, @unchecked Sendable {
    let isMock = false

    /// Called on an arbitrary thread when a decode fails. Throttled by the
    /// engine to the first failure and then once every 32 consecutive ones.
    var onEngineError: ((String) -> Void)?

    private let modelPath: String
    let languageCode: String
    let lib: any CrispASRLibraryAPI

    // Window/endpointing knobs (mirrors the CLI defaults where sensible).
    static let sampleRate = 16000
    static let stepSamples = 1 * sampleRate // decode cadence
    static let lengthSamples = 10 * sampleRate // rolling window cap
    /// How much confirmed silence after the last VAD speech span triggers a
    /// final. Must stay ≥ the VAD's `min_silence_ms` (below) — that is what
    /// makes a span end + this much analyzed audio a *confirmed* silence gap.
    static let endpointSamples = 1250 * sampleRate / 1000
    /// Forced-final cap: safety net under VAD, and the only endpoint when the
    /// VAD model is unavailable (degraded mode).
    static let utteranceCapSamples = 12 * sampleRate
    /// Tail kept in the rolling window after a final, for decode context.
    static let windowKeepTailSamples = 200 * sampleRate / 1000
    static let minDecodeSamples = 2 * sampleRate // encoder conv-kernel floor
    /// Backstop only (never used for endpointing): marks a buffer as not
    /// truly silent so the cap path never decodes known-silent audio.
    static let speechRMS: Float = 1e-3
    /// Total budget for `finish()` to wait out in-flight decode/VAD jobs.
    /// Bounds the whole drain, not each semaphore wait — a hung C call never
    /// clears its in-flight flag, so per-wait timeouts alone would re-arm
    /// forever. (The synchronous flush decode below stays unbounded: it is a
    /// single direct C call on the session, and aborting mid-call would leave
    /// the C library using a session this side has already torn down.)
    static let drainTimeout: TimeInterval = 30

    // FireRedVAD (via the dispatcher-backed crispasr_vad_slices ABI; the
    // model is process-cached in the C library after the first call).
    static let vadCheckIntervalSamples = 500 * sampleRate / 1000
    static let vadThreshold: Float = 0.5
    static let vadMinSpeechMS = 250
    /// Must equal `endpointSamples` — see the comment there.
    static let vadMinSilenceMS = 1000
    static let vadPadMS = 30
    /// Don't discard a short speechless buffer on a single VAD pass — onsets
    /// can be missed on very short windows; wait until the buffer is at
    /// least this long before trusting a zero-span verdict.
    static let vadMinDiscardSamples = 2 * sampleRate

    /// `library` is injectable so tests can drive the full state machine over
    /// a scripted fake without dlopen; nil (the default) binds the real dylib.
    init(
        modelPath: URL,
        languageCode: String = "ja",
        library: (any CrispASRLibraryAPI)? = nil
    ) throws {
        self.modelPath = modelPath.path
        self.languageCode = languageCode
        lib = try library ?? CrispASRLibrary.open()
        if let vad = lib.vadModelPath {
            vadModelPath = vad
        } else {
            vadModelPath = nil
            vadUnavailableReason =
                "VAD unavailable (missing firered-vad.gguf or libcrispasr VAD symbols) — " +
                "finalization falls back to the \(Self.utteranceCapSamples / Self.sampleRate)s cap"
        }
    }

    // MARK: - State

    let lock = NSLock()
    /// Serializes `prepare` so a background warm-up and a session start can
    /// never both open a C session (the second opener would leak the first).
    let prepareLock = NSLock()
    let decodeQueue = DispatchQueue(label: "dev.mimi.asr.decode", qos: .userInitiated)
    let vadQueue = DispatchQueue(label: "dev.mimi.asr.vad", qos: .userInitiated)
    /// Signaled after every decode or VAD completion so `finish` can wait
    /// out in-flight work. Never waited on by the job paths themselves.
    let jobFinished = DispatchSemaphore(value: 0)

    var session: OpaquePointer?

    var totalSamples = 0
    var window: [Float] = [] // last `lengthSamples` samples
    var utterance: [Float] = [] // PCM since the last final
    var utteranceStartSample = 0
    /// Bumped on every final/discard so stale VAD results (snapshot taken
    /// before the reset) can be ignored.
    var utteranceGeneration = 0
    var lastDecodeDispatchSample = 0
    /// `vadLastSpeechEndSample` at the time the last partial was dispatched.
    /// Partials only re-decode when the VAD has confirmed speech beyond this,
    /// so a pause doesn't chain identical window redecodes (which would both
    /// freeze the HUD draft and starve the VAD on the serial decode queue).
    var lastPartialSpeechEndSample = 0
    var processedCount = 0
    var decodeInFlight = false
    var vadInFlight = false
    var finishing = false
    var inbox: [ASREvent] = []
    var consecutiveDecodeFailures = 0

    /// VAD state (all guarded by `lock`).
    var vadModelPath: String?
    /// Set in init when the VAD can't be used; reported once in `prepare`.
    private var vadUnavailableReason: String?
    private var vadUnavailableReported = false
    /// Flipped off at runtime on VAD failure → degraded mode for the session.
    var vadEnabled = true
    var consecutiveVADFailures = 0
    var lastVADDispatchSample = 0
    /// True once the VAD has found a speech span in the current utterance.
    var utteranceHasSpeech = false
    /// RMS backstop: any chunk since the last final/discard was not silent.
    var utteranceHasLoudAudio = false
    /// Absolute sample of the end of the last VAD speech span (nil = none yet).
    var vadLastSpeechEndSample: Int?
    /// Absolute sample through which VAD results are valid for the current
    /// utterance (0 = nothing analyzed). Endpointing only trusts a span end
    /// once analysis has progressed past it.
    var vadAnalyzedThroughSample = 0
    /// Absolute sample of the start of the first speech span in the utterance.
    var vadFirstSpeechStartSample: Int?

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
        let alreadyOpen = lock.withLock { session != nil }
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
        lib.setGpuBackend("metal")
        guard let handle = lib.openSession(modelPath: modelPath, backend: "qwen3") else {
            throw ASREngineError.createFailed("crispasr_session_open_explicit failed (backend qwen3)")
        }
        // Publish the handle under the state lock: `close()` nils it there,
        // and finish/runDecode snapshot it there.
        lock.withLock { session = handle }
        if let reason = vadUnavailableReason, !vadUnavailableReported {
            vadUnavailableReported = true
            #if DEBUG
                print("[asr] \(reason)")
            #endif
            onEngineError?(reason)
        }
    }

    func openStream() throws {
        lock.withLock {
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
    }

    func push(_ samples: [Float]) {
        lock.withLock {
            guard session != nil, !finishing else { return }
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
        }
    }
}
