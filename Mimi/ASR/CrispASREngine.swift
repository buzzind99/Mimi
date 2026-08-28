import Foundation

/// Swift wrapper over `libcrispasr.dylib` (stable C session ABI, bound at
/// runtime with dlopen/dlsym so the app builds and launches before the native
/// runtime is installed).
///
/// Runs the Qwen3-ASR backend (`qwen3`), which has no cache-aware streaming —
/// the sliding window lives here instead of in the C library:
///
///   - `push` appends 160 ms chunks to a rolling buffer and tracks speech
///     energy (RMS gate) for endpointing.
///   - A `step`-spaced window decode posts `.partial` events (HUD draft text).
///   - 800 ms of trailing silence redecodes the buffered utterance PCM
///     (CrispASR's "redecode" final mode) and posts one clean `.final`.
///
/// Threading: pushes land on the caller's audio thread but only take the
/// state lock; actual decoding runs on a dedicated serial queue so the main
/// thread's 60 ms `poll()` loop never blocks behind a multi-second decode.
/// The session itself is only ever touched by one decode at a time.
final class CrispASREngine: Transcriber {
    let isMock = false

    /// Called on an arbitrary thread when a decode fails. Throttled by the
    /// engine to the first failure and then once every 32 consecutive ones.
    var onEngineError: ((String) -> Void)?

    private let modelPath: String
    private let languageCode: String

    // Window/endpointing knobs (mirrors the CLI defaults where sensible).
    private static let sampleRate = 16_000
    private static let stepSamples = 1 * sampleRate       // decode cadence
    private static let lengthSamples = 10 * sampleRate    // rolling window cap
    private static let endpointSamples = 800 * sampleRate / 1000
    private static let utteranceCapSamples = 60 * sampleRate
    private static let minDecodeSamples = 2 * sampleRate  // encoder conv-kernel floor
    private static let speechRMS: Float = 1e-3

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

    private var fnSetGpuBackend: FnSetGpuBackend!
    private var fnOpenExplicit: FnOpenExplicit!
    private var fnSessionClose: FnSessionClose!
    private var fnTranscribeLang: FnTranscribeLang!
    private var fnResultNSegments: FnResultNSegments!
    private var fnResultSegmentText: FnResultSegmentText!
    private var fnResultFree: FnResultFree!

    init(modelPath: URL, languageCode: String = "ja") throws {
        self.modelPath = modelPath.path
        self.languageCode = languageCode
        let handle = try Self.openLibrary()
        bind(from: handle)
    }

    // MARK: - Library binding

    private static let dylibCandidates: [String?] = [
        // Test/CI override (absolute path).
        ProcessInfo.processInfo.environment["MIMI_ASR_DYLIB"],
        // Bare name: resolved via the app's LC_RPATH (covers the dev
        // checkout via $(SRCROOT)/local/frameworks and the bundle via
        // @executable_path/../Frameworks).
        "libcrispasr.dylib",
        Bundle.main.privateFrameworksPath.map { $0 + "/libcrispasr.dylib" },
        Bundle.main.path(forResource: "libcrispasr", ofType: "dylib"),
        Bundle.main.path(
            forResource: "libcrispasr", ofType: "dylib", inDirectory: "Frameworks"),
        // Development fallback (repo checkout before bundling).
        FileManager.default.currentDirectoryPath
            + "/local/frameworks/crispasr/libcrispasr.dylib",
    ]

    private static func openLibrary() throws -> UnsafeMutableRawPointer {
        var lastError = "no candidate paths"
        for candidate in dylibCandidates {
            guard let path = candidate else { continue }
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                return handle
            }
            if let err = dlerror() { lastError = String(cString: err) }
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

        guard fnSetGpuBackend != nil, fnOpenExplicit != nil, fnSessionClose != nil,
            fnTranscribeLang != nil, fnResultNSegments != nil, fnResultSegmentText != nil,
            fnResultFree != nil
        else {
            preconditionFailure("libcrispasr: missing required symbols")
        }
    }

    // MARK: - State

    private let lock = NSLock()
    private let decodeQueue = DispatchQueue(label: "dev.mimi.asr.decode", qos: .userInitiated)
    /// Signaled after every decode completion so `finish` can wait out an
    /// in-flight decode. Never waited on by the decode path itself.
    private let decodeFinished = DispatchSemaphore(value: 0)

    private var session: OpaquePointer?

    private var totalSamples = 0
    private var window: [Float] = []          // last `lengthSamples` samples
    private var utterance: [Float] = []       // PCM since the last final
    private var utteranceStartSample = 0
    private var lastSpeechSample: Int?
    private var lastDecodeDispatchSample = 0
    private var processedCount = 0
    private var decodeInFlight = false
    private var finishing = false
    private var inbox: [ASREvent] = []
    private var consecutiveDecodeFailures = 0

    var processedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return processedCount
    }

    // MARK: - Transcriber

    func prepare() throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ASREngineError.modelNotFound(modelPath)
        }
        // TLS-backed GPU preference: must be set on the same thread that
        // opens the session (prepare runs once, before any decode starts).
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
    }

    func openStream() throws {
        lock.lock(); defer { lock.unlock() }
        totalSamples = 0
        window = []
        utterance = []
        utteranceStartSample = 0
        lastSpeechSample = nil
        lastDecodeDispatchSample = 0
        processedCount = 0
        decodeInFlight = false
        finishing = false
        inbox = []
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

        var energy: Float = 0
        for s in samples { energy += s * s }
        let rms = (energy / Float(max(1, samples.count))).squareRoot()
        let hasSpeech = rms > Self.speechRMS
        if hasSpeech {
            if utterance.isEmpty {
                utteranceStartSample = totalSamples - samples.count
            }
            utterance.append(contentsOf: samples)
            lastSpeechSample = totalSamples
        } else if !utterance.isEmpty {
            // Keep trailing silence so the redecode sees a natural tail.
            utterance.append(contentsOf: samples)
        }

        maybeScheduleDecodeLocked()
        lock.unlock()
    }

    /// Caller holds `lock`. Dispatches either an endpoint (final) decode or a
    /// step-spaced window (partial) decode when one is due.
    private func maybeScheduleDecodeLocked() {
        guard session != nil, !finishing, !decodeInFlight else { return }

        let silence = totalSamples - (lastSpeechSample ?? 0)
        let utteranceFull = utterance.count >= Self.utteranceCapSamples
        if !utterance.isEmpty, lastSpeechSample != nil,
            (silence >= Self.endpointSamples || utteranceFull) {
            // Endpoint: redecode the whole utterance span for a clean final.
            let pcm = utterance
            let start = utteranceStartSample
            let end = lastSpeechSample ?? totalSamples
            decodeInFlight = true
            decodeQueue.async { [weak self] in
                self?.runDecode(pcm: pcm, start: start, end: end, isFinal: true)
            }
            return
        }

        let hasNewAudio = totalSamples - lastDecodeDispatchSample >= Self.stepSamples
        if !utterance.isEmpty, hasNewAudio {
            let pcm = window
            let end = totalSamples
            decodeInFlight = true
            decodeQueue.async { [weak self] in
                self?.runDecode(pcm: pcm, start: max(0, end - pcm.count), end: end, isFinal: false)
            }
            lastDecodeDispatchSample = totalSamples
        }
    }

    /// Runs on `decodeQueue`. One decode at a time (guarded by `decodeInFlight`
    /// and the serial queue); posts results into the inbox under `lock`.
    private func runDecode(pcm: [Float], start: Int, end: Int, isFinal: Bool) {
        defer {
            decodeFinished.signal()
            lock.lock()
            decodeInFlight = false
            // A decode finishing may mean the next step is already due.
            maybeScheduleDecodeLocked()
            lock.unlock()
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
        guard let result else {
            reportDecodeFailure()
            return
        }
        defer { fnResultFree(result) }

        var text = ""
        let n = fnResultNSegments(result)
        for i in 0..<max(0, n) {
            if let seg = fnResultSegmentText(result, i) {
                text += String(cString: seg)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        processedCount = max(processedCount, end)
        if isFinal {
            inbox.append(.final(text: text, startSample: start, endSample: end, lang: languageCode))
            utterance = []
            utteranceStartSample = 0
            lastSpeechSample = nil
        } else {
            inbox.append(.partial(text: text))
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

    func poll() -> ASREvent? {
        lock.lock(); defer { lock.unlock() }
        guard !inbox.isEmpty else { return nil }
        return inbox.removeFirst()
    }

    func finish() -> [ASREvent] {
        lock.lock()
        finishing = true
        lock.unlock()
        // Wait (bounded) for any in-flight decode to post its result.
        while true {
            lock.lock()
            let inFlight = decodeInFlight
            lock.unlock()
            if !inFlight { break }
            _ = decodeFinished.wait(timeout: .now() + 30)
        }

        // Flush any open utterance synchronously — capture has already
        // stopped, so nothing new can arrive.
        lock.lock()
        let pcm = utterance
        let start = utteranceStartSample
        let end = lastSpeechSample ?? totalSamples
        let hadSpeech = !pcm.isEmpty
        lock.unlock()

        if hadSpeech, session != nil {
            var padded = pcm
            if padded.count < Self.minDecodeSamples {
                padded.append(
                    contentsOf: [Float](repeating: 0, count: Self.minDecodeSamples - padded.count))
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
                for i in 0..<max(0, n) {
                    if let seg = fnResultSegmentText(result, i) {
                        text += String(cString: seg)
                    }
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    inbox.append(.final(
                        text: text, startSample: start, endSample: end, lang: languageCode))
                }
            }
        }

        lock.lock()
        let drained = inbox
        inbox = []
        let sessionHandle = session
        session = nil
        lock.unlock()
        if let sessionHandle {
            fnSessionClose(sessionHandle)
        }
        return drained
    }
}
