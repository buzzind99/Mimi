import Foundation

/// Streaming transcriber abstraction. The native engine wraps the NeMo-Speech
/// C ABI; the mock keeps the whole pipeline testable without the runtime.
protocol Transcriber: AnyObject {
    /// Prepare the recognizer (model load) before the stream opens.
    func prepare() throws
    /// Open a streaming recognition session.
    func openStream() throws
    /// Push one 16 kHz mono chunk into the stream.
    func push(_ samples: [Float])
    /// Poll for the next available result (partial or final); nil = need more audio.
    func poll() -> ASREvent?
    /// Finish the stream and drain remaining finals. Strictly ordered teardown:
    /// capture stops first, then finish → drain → close → destroy.
    func finish() -> [ASREvent]
    /// Samples actually processed by the decoder (latency readback).
    var processedSamples: Int { get }
    var isMock: Bool { get }
}

enum ASREngineError: LocalizedError {
    case runtimeNotFound(String)
    case modelNotFound(String)
    case createFailed(String)
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound(let detail):
            return "ASR runtime not found (\(detail)). Build it with scripts/build_runtime.sh, or drop the GGUF into the models folder to use the mock."
        case .modelNotFound(let path):
            return "ASR model not found at \(path)."
        case .createFailed(let detail):
            return "Failed to create ASR recognizer: \(detail)"
        case .streamFailed(let detail):
            return "Failed to open ASR stream: \(detail)"
        }
    }
}

/// Swift wrapper over `libnemo_speech_asr_c.dylib` (stable C ABI, bound at
/// runtime with dlopen/dlsym so the app builds and launches before the native
/// runtime is installed).
///
/// Threading: every native call is serialized onto a dedicated queue that owns
/// the stream handle. Teardown is strictly ordered — capture stops first, then
/// `stream_finish` → drain finals → `stream_close` → `nemo_speech_asr_destroy`.
final class NativeASREngine: Transcriber {
    let isMock = false

    private let queue = DispatchQueue(label: "dev.mimi.asr", qos: .userInitiated)
    private let modelPath: String
    private let languageCode: String

    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?

    // Bound C functions.
    private typealias FnCreate = @convention(c) (
        UnsafePointer<nemo_speech_asr_recognizer_config>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> nemo_speech_asr_status
    private typealias FnDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias FnStreaming = @convention(c) (
        OpaquePointer?,
        UnsafePointer<nemo_speech_asr_recognition_options>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> nemo_speech_asr_status
    private typealias FnPush = @convention(c) (
        OpaquePointer?, UnsafePointer<Float>?, Int, Int32
    ) -> nemo_speech_asr_status
    private typealias FnFinish = @convention(c) (OpaquePointer?) -> nemo_speech_asr_status
    private typealias FnNext = @convention(c) (
        OpaquePointer?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> nemo_speech_asr_status
    private typealias FnStreamClose = @convention(c) (OpaquePointer?) -> Void
    private typealias FnResultDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias FnResultIsFinal = @convention(c) (OpaquePointer?) -> Bool
    private typealias FnResultAudioProcessed = @convention(c) (OpaquePointer?) -> Float
    private typealias FnResultString = @convention(c) (OpaquePointer?, Int) -> UnsafePointer<CChar>?
    private typealias FnLastError = @convention(c) () -> UnsafePointer<CChar>?
    private typealias FnOptionsDefault = @convention(c) () -> nemo_speech_asr_recognition_options

    private var fnCreate: FnCreate!
    private var fnDestroy: FnDestroy!
    private var fnStreaming: FnStreaming!
    private var fnPush: FnPush!
    private var fnFinish: FnFinish!
    private var fnNext: FnNext!
    private var fnStreamClose: FnStreamClose!
    private var fnResultDestroy: FnResultDestroy!
    private var fnResultIsFinal: FnResultIsFinal!
    private var fnResultAudioProcessed: FnResultAudioProcessed!
    private var fnResultTranscript: FnResultString!
    private var fnResultLanguage: FnResultString!
    private var fnLastError: FnLastError!
    private var fnOptionsDefault: FnOptionsDefault!

    private var pushedSamples = 0
    private var lastFinalEndSample = 0
    private var processedCount = 0
    private var consecutivePushFailures = 0

    var processedSamples: Int {
        queue.sync { processedCount }
    }

    /// Silence length that closes a streaming utterance (mid-stream finals).
    /// Matches SentenceBuffer's 1 s silence tier with headroom.
    static let endpointSilenceMS = 800

    /// Called on the ASR queue when a push fails. Throttled to the first
    /// failure and then once every 32 consecutive failures; `count` is the
    /// current consecutive-failure tally.
    var onPushError: ((Int, String) -> Void)?

    /// Bounded in-flight pushes so the worker never outruns ASR indefinitely.
    private let inFlight = DispatchSemaphore(value: 16)

    init(modelPath: URL, languageCode: String = "ja-JP") throws {
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
        "libnemo_speech_asr_c.dylib",
        Bundle.main.privateFrameworksPath.map { $0 + "/libnemo_speech_asr_c.dylib" },
        Bundle.main.path(forResource: "libnemo_speech_asr_c", ofType: "dylib"),
        Bundle.main.path(
            forResource: "libnemo_speech_asr_c", ofType: "dylib", inDirectory: "Frameworks"),
        // Development fallback (repo checkout before bundling).
        FileManager.default.currentDirectoryPath + "/local/frameworks/libnemo_speech_asr_c.dylib",
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
        fnCreate = fn("nemo_speech_asr_create", FnCreate.self)
        fnDestroy = fn("nemo_speech_asr_destroy", FnDestroy.self)
        fnStreaming = fn("nemo_speech_asr_streaming_recognize", FnStreaming.self)
        fnPush = fn("nemo_speech_asr_stream_push_f32", FnPush.self)
        fnFinish = fn("nemo_speech_asr_stream_finish", FnFinish.self)
        fnNext = fn("nemo_speech_asr_stream_next", FnNext.self)
        fnStreamClose = fn("nemo_speech_asr_stream_close", FnStreamClose.self)
        fnResultDestroy = fn("nemo_speech_asr_result_destroy", FnResultDestroy.self)
        fnResultIsFinal = fn("nemo_speech_asr_result_is_final", FnResultIsFinal.self)
        fnResultAudioProcessed = fn("nemo_speech_asr_result_audio_processed", FnResultAudioProcessed.self)
        fnResultTranscript = fn("nemo_speech_asr_result_transcript", FnResultString.self)
        fnResultLanguage = fn("nemo_speech_asr_result_language_code", FnResultString.self)
        fnLastError = fn("nemo_speech_asr_last_error", FnLastError.self)
        fnOptionsDefault = fn("nemo_speech_asr_recognition_options_default", FnOptionsDefault.self)

        guard fnCreate != nil, fnDestroy != nil, fnStreaming != nil, fnPush != nil,
            fnFinish != nil, fnNext != nil, fnStreamClose != nil, fnResultDestroy != nil,
            fnResultIsFinal != nil, fnResultTranscript != nil
        else {
            preconditionFailure("libnemo_speech_asr_c: missing required symbols")
        }
    }

    private func lastErrorText() -> String {
        if let c = fnLastError?() { return String(cString: c) }
        return "unknown error"
    }

    // MARK: - Transcriber

    func prepare() throws {
        try queue.sync {
            guard recognizer == nil else { return }
            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw ASREngineError.modelNotFound(modelPath)
            }
            var backend = nemo_speech_asr_backend_config()
            backend.size = MemoryLayout<nemo_speech_asr_backend_config>.size
            backend.gpu = 0 // Metal backend (metal-asr preset), device 0
            var model = nemo_speech_asr_model_config()
            model.size = MemoryLayout<nemo_speech_asr_model_config>.size
            // Mid-stream finals: without endpointing the stream only emits
            // partials until finish(); SentenceBuffer and the latency readout
            // are both driven by finals.
            var endpointing = nemo_speech_asr_endpointing_config()
            endpointing.size = MemoryLayout<nemo_speech_asr_endpointing_config>.size
            endpointing.enable = true
            endpointing.vad_based = false
            endpointing.stop_history_eou_ms = Int32(Self.endpointSilenceMS)
            let pathStorage = modelPath.utf8CString
            var out: OpaquePointer?
            let status = pathStorage.withUnsafeBufferPointer { path -> nemo_speech_asr_status in
                model.path = path.baseAddress
                model.name = nil
                var config = nemo_speech_asr_recognizer_config()
                config.size = MemoryLayout<nemo_speech_asr_recognizer_config>.size
                return withUnsafePointer(to: &backend) { backendPtr in
                    withUnsafePointer(to: &model) { modelPtr in
                        withUnsafePointer(to: &endpointing) { endpointingPtr in
                            config.backend = backendPtr
                            config.model = modelPtr
                            config.endpointing = endpointingPtr
                            return fnCreate(&config, &out)
                        }
                    }
                }
            }
            guard status == NEMO_SPEECH_ASR_OK, let handle = out else {
                throw ASREngineError.createFailed(lastErrorText())
            }
            recognizer = handle
        }
    }

    func openStream() throws {
        try queue.sync {
            guard let recognizer else { throw ASREngineError.streamFailed("recognizer not created") }
            var out: OpaquePointer?
            var options = nemo_speech_asr_recognition_options()
            if let defaultFn = fnOptionsDefault {
                options = defaultFn()
            }
            let status: nemo_speech_asr_status = languageCode.withCString { lang in
                options.language_code = lang
                options.interim_results = true
                return fnStreaming(recognizer, &options, &out)
            }
            guard status == NEMO_SPEECH_ASR_OK, let streamHandle = out else {
                throw ASREngineError.streamFailed(lastErrorText())
            }
            stream = streamHandle
            pushedSamples = 0
            lastFinalEndSample = 0
            processedCount = 0
        }
    }

    func push(_ samples: [Float]) {
        inFlight.wait()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.inFlight.signal() }
            guard let stream = self.stream else { return }
            var status = NEMO_SPEECH_ASR_OK
            samples.withUnsafeBufferPointer { buf in
                status = self.fnPush(stream, buf.baseAddress, samples.count, 16_000)
            }
            if status == NEMO_SPEECH_ASR_OK {
                self.consecutivePushFailures = 0
                self.pushedSamples += samples.count
            } else {
                // A failed push silently starves the decoder (next() keeps
                // returning "need more audio" forever) — never ignore it.
                self.consecutivePushFailures += 1
                self.reportPushFailure()
            }
        }
    }

    private func reportPushFailure() {
        let n = consecutivePushFailures
        guard n == 1 || n % 32 == 0 else { return }
        let message = "ASR stream push failed (×\(n)): \(lastErrorText())"
        #if DEBUG
        print("[asr] \(message)")
        #endif
        onPushError?(n, message)
    }

    func poll() -> ASREvent? {
        queue.sync { () -> ASREvent? in
            guard let stream else { return nil }
            var out: OpaquePointer?
            let status = fnNext(stream, &out)
            guard status == NEMO_SPEECH_ASR_OK else {
                #if DEBUG
                print("[asr] stream next failed: \(lastErrorText())")
                #endif
                return nil
            }
            guard let result = out else { return nil }
            defer { fnResultDestroy(result) }
            return makeEvent(result: result)
        }
    }

    private func makeEvent(result: OpaquePointer) -> ASREvent? {
        // Track the decoder cursor on every result (partials included) so the
        // latency readout advances continuously, not only at finals.
        let processed = fnResultAudioProcessed?(result) ?? 0
        let processedSample = Int(processed * Float(SessionClock.sampleRate))
        processedCount = max(processedCount, processedSample)

        let isFinal = fnResultIsFinal(result)
        let text = fnResultTranscript(result, 0).map { String(cString: $0) } ?? ""
        guard !text.isEmpty else { return nil }
        if isFinal {
            let endSample = max(processedSample, pushedSamples)
            processedCount = max(processedCount, endSample)
            let startSample = lastFinalEndSample
            lastFinalEndSample = endSample
            let lang = fnResultLanguage?(result, 0).map { String(cString: $0) } ?? "ja"
            return .final(text: text, startSample: startSample, endSample: endSample, lang: lang)
        }
        return .partial(text: text)
    }

    func finish() -> [ASREvent] {
        queue.sync { () -> [ASREvent] in
            guard let stream else { return [] }
            _ = fnFinish(stream)
            var drained: [ASREvent] = []
            while true {
                var out: OpaquePointer?
                let status = fnNext(stream, &out)
                guard status == NEMO_SPEECH_ASR_OK, let result = out else { break }
                defer { fnResultDestroy(result) }
                if let event = makeEvent(result: result) {
                    drained.append(event)
                }
            }
            fnStreamClose(stream)
            self.stream = nil
            if let recognizer {
                fnDestroy(recognizer)
                self.recognizer = nil
            }
            return drained
        }
    }
}

/// Pure-Swift stand-in used when the native runtime is unavailable. Emits
/// deterministic pseudo transcripts driven by the (gated) audio energy so the
/// full pipeline — buffering, translation, UI, export — stays exercisable.
/// The UI labels mock sessions clearly.
final class MockASREngine: Transcriber {
    let isMock = true

    private static let canned = [
        "今日はいい天気ですね。",
        "これから配信を始めます、よろしくお願いします。",
        "新しいゲーム、みんな遊んだ？",
        "チャットの質問に答えていきますね。",
        "次の話題に移ります、面白いですよ。",
    ]

    private var speechChunksSeen = 0
    private var nextSentenceAt = 6
    private var pendingFinal: String?
    private var cannedIndex = 0
    private var totalSamples = 0
    private var lastFinalEnd = 0

    var processedSamples: Int { totalSamples }

    func prepare() throws {}
    func openStream() throws {}

    func push(_ samples: [Float]) {
        totalSamples += samples.count
        var energy: Float = 0
        for s in samples { energy += s * s }
        let rms = (energy / Float(max(1, samples.count))).squareRoot()
        if rms > 1e-3 {
            speechChunksSeen += 1
        }
        if pendingFinal == nil, speechChunksSeen >= nextSentenceAt {
            pendingFinal = Self.canned[cannedIndex % Self.canned.count]
            cannedIndex += 1
            nextSentenceAt = speechChunksSeen + Int.random(in: 5...12)
        }
    }

    func poll() -> ASREvent? {
        guard let text = pendingFinal else { return nil }
        pendingFinal = nil
        let end = totalSamples
        let start = lastFinalEnd
        lastFinalEnd = end
        return .final(text: text, startSample: start, endSample: end, lang: "ja")
    }

    func finish() -> [ASREvent] { [] }
}

/// Builds the right engine for a session: native when the runtime + model
/// resolve, mock otherwise.
enum ASREngineFactory {
    static func makeEngine(modelURL: URL?, allowMock: Bool) -> Transcriber? {
        if let modelURL, let engine = try? NativeASREngine(modelPath: modelURL) {
            return engine
        }
        return allowMock ? MockASREngine() : nil
    }
}
