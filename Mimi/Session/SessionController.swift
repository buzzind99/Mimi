import Foundation

/// Owns the mechanics of a live capture → ASR session: engine lifecycle and
/// warm-up scheduling, system-audio capture wiring, sentence buffering, and
/// the poll/tick timers. Published UI state, translation configuration, and
/// export delegation stay in `AppModel`, which plugs in via the callbacks.
@MainActor
final class SessionController {
    /// Upper bound for the translation-tail drain in `stop()`. Also part of
    /// the quit-time watchdog budget in `AppDelegate`.
    static let translationDrainTimeout: TimeInterval = 5

    private let live: LivePartialState
    private let latency: LatencyState
    private let translationQueue: TranslationQueue
    private let makeEngine: @Sendable (URL?, Bool) -> ASREngine?
    private let makeCapture: () -> any AudioCapturing
    private let ensurePermission: () async -> Bool
    private let warmUpEnabled: () -> Bool

    /// A session is about to run: clear transcript state.
    var onSessionBegin: (() -> Void)?
    /// The engine was created for a new session.
    var onEngineChosen: ((_ isMock: Bool, _ modelURL: URL?) -> Void)?
    /// A sentence left the buffer (append to transcript + enqueue translation).
    var onSentence: ((Sentence) -> Void)?
    /// The engine surfaced an internal error.
    var onEngineError: ((String) -> Void)?
    /// The capture stream died mid-session.
    var onCaptureError: ((String) -> Void)?

    /// Metadata captured at the start of the most recent session (export).
    private(set) var sessionMetadata: SessionMetadata?

    private var engine: ASREngine?
    private var capture: (any AudioCapturing)?
    private var sentenceBuffer: SentenceBuffer?
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    /// Path of the model the warm-up last loaded (nil = none yet). Keyed on
    /// path so the warm-up re-arms when the user switches models: the new
    /// GGUF gets prepared in the background instead of loading synchronously
    /// inside the first `begin` after the switch. Repeat calls with the same
    /// path are no-ops.
    private var warmedModelPath: String?
    #if DEBUG
        private var debugIngressChunks = 0
    #endif

    /// Injection seams for tests: engine, capture, and permission default to
    /// the real implementations; tests inject doubles so `begin()` and the
    /// event paths run without TCC, ScreenCaptureKit, or the native runtime.
    /// `makeEngine` receives `allowMock` (true from `begin`, false from the
    /// warm-up, which must never fall back to the mock). `warmUpEnabled`
    /// defaults to off inside a unit-test host: that app runs the real launch
    /// path during `xcodebuild test`, and its detached warm-up would construct
    /// a real engine that races the suites' own engine constructions into a
    /// permanent ggml-metal init wedge. Warm-up tests opt back in explicitly.
    init(
        live: LivePartialState,
        latency: LatencyState,
        translationQueue: TranslationQueue,
        makeEngine: @escaping @Sendable (URL?, Bool) -> ASREngine? = {
            ASREngineFactory.makeEngine(modelURL: $0, allowMock: $1)
        },
        makeCapture: @escaping () -> any AudioCapturing = { SystemAudioCapture() },
        ensurePermission: @escaping () async -> Bool = {
            await SystemAudioCapture.ensurePermission()
        },
        warmUpEnabled: @escaping () -> Bool = {
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        }
    ) {
        self.live = live
        self.latency = latency
        self.translationQueue = translationQueue
        self.makeEngine = makeEngine
        self.makeCapture = makeCapture
        self.ensurePermission = ensurePermission
        self.warmUpEnabled = warmUpEnabled
    }

    // MARK: - Warm-up

    /// Loads the ASR model + compiles the Metal pipelines in the background
    /// (at app launch, when a model becomes available, or after a model
    /// switch) so the first session start is instant. Safe against racing
    /// `begin`: the engine's `prepare` is serialized, and a second opener
    /// reuses the already-open session.
    func warmUpIfNeeded(modelURL: URL?) {
        guard warmUpEnabled(), let url = modelURL, warmedModelPath != url.path else { return }
        warmedModelPath = url.path
        #if DEBUG
            print("[warmup] preparing ASR engine in background")
        #endif
        let makeEngine = self.makeEngine
        Task.detached(priority: .utility) {
            if let engine = makeEngine(url, false) {
                try? engine.prepare()
            }
        }
    }

    // MARK: - Session control

    /// Brings up permission → engine → capture → buffer. Returns `false` when
    /// no model is available (caller maps that to `.needsModel`); throws when
    /// permission or capture setup fails. `modelURL` comes from the caller's
    /// resolved state (single resolve, no second verify on the start path);
    /// `modelID` is the active choice's id for session metadata.
    func begin(modelURL: URL?, modelID: String) async throws -> Bool {
        // Screen Recording permission (TCC) covers SCK system-audio capture.
        guard await ensurePermission() else {
            throw CaptureError.permissionDenied
        }

        guard let engine = makeEngine(modelURL, true) else {
            return false
        }
        self.engine = engine
        onEngineChosen?(engine.isMock, modelURL)
        engine.onEngineError = { [weak self] message in
            Task { @MainActor in self?.onEngineError?(message) }
        }

        onSessionBegin?()
        live.partial = ""
        latency.reset()

        let buffer = SentenceBuffer()
        buffer.onSentence = { [weak self] sentence in
            self?.onSentence?(sentence)
        }
        sentenceBuffer = buffer

        let capture = makeCapture()
        // The engine is captured strongly: a session owns exactly one engine,
        // and chunks must not read main-actor state from the SCK output
        // queue. `capture.stop()` fences chunks after teardown.
        capture.onChunk = { [weak self] chunk in
            guard let self else { return }
            self.handleCaptureChunk(chunk, engine: engine)
        }
        capture.onIOError = { [weak self] error in
            Task { @MainActor in self?.onCaptureError?(error.localizedDescription) }
        }
        self.capture = capture

        #if DEBUG
            print("[session] start: whole-system SCK audio capture")
        #endif
        try await capture.start()

        // `prepare` may wait out a multi-second GGUF load + Metal compile
        // (when the background warm-up hasn't finished) — keep it off the
        // main actor. `prepareLock` still serializes it against the warm-up.
        try await Task.detached(priority: .userInitiated) { try engine.prepare() }.value
        try engine.openStream()

        sessionMetadata = SessionMetadata(
            startedAt: Date(),
            sourceLang: "ja",
            targetLang: "en",
            model: engine.isMock ? "mock" : modelID,
            chunkMS: 160
        )

        return true
    }

    /// Teardown, ordered so pending translations finish first: capture and
    /// ASR are shut down immediately, the final flushed sentence is enqueued,
    /// and only after the translation queue drains (bounded by a timeout)
    /// does the session wind down. That keeps the tail of the session
    /// exportable with translations intact.
    ///
    /// The engine stays warm: the loaded model is reused by the next session.
    func stop() async {
        // Strictly ordered teardown: capture stops first (synchronous fence),
        // then the ASR finish → drain runs off-main — `finish` does a bounded
        // drain wait plus a synchronous flush decode, a multi-second C call
        // whenever speech is in flight at Stop.
        capture?.stop()
        if let engine {
            let drained = await Task.detached(priority: .userInitiated) { engine.finish() }.value
            for event in drained {
                handleASREvent(event)
            }
        }
        engine = nil
        capture = nil
        stopTimers()

        // Flush a partially-formed sentence (its translation is awaited
        // below), then let the translation worker finish its tail.
        sentenceBuffer?.flush()
        sentenceBuffer = nil
        _ = await translationQueue.drain(timeout: Self.translationDrainTimeout)
        live.partial = ""
    }

    // MARK: - Capture (ASR queue)

    private func handleCaptureChunk(_ chunk: AudioChunk, engine: ASREngine) {
        engine.push(chunk.samples)
        #if DEBUG
            logIngressEnergy(chunk)
        #endif
    }

    #if DEBUG
        /// Every ~8 s of audio, print ASR-ingress energy so a dead pipeline
        /// (all-zero audio reaching the model) is obvious.
        private func logIngressEnergy(_ chunk: AudioChunk) {
            debugIngressChunks += 1
            guard debugIngressChunks % 50 == 0 else { return }
            let rms = AudioLevels.rms(of: chunk.samples)
            print(
                "[capture] chunk #\(debugIngressChunks) rms=\(String(format: "%.6f", rms)) " +
                    "t=\(SessionClock.timestamp(SessionClock.seconds(chunk.startSample)))"
            )
        }
    #endif

    // MARK: - Timers

    func startTimers() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollASR() }
        }
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sentenceBuffer?.tick() }
        }
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
    }

    private func pollASR() {
        guard let engine else { return }
        while let event = engine.poll() {
            handleASREvent(event)
        }
        // Latency rides the existing 60 ms tick (no per-chunk Task hop): the
        // 0.1 s rounding gate in `LatencyState` keeps publishes visible-only.
        latency.update(
            max(0, Double(engine.pushedSamples - engine.processedSamples) / SessionClock.sampleRate)
        )
    }

    // MARK: - Event handling (main actor)

    private func handleASREvent(_ event: ASREvent) {
        switch event {
        case let .partial(text):
            live.partial = text
        case let .final(text, startSample, endSample, lang):
            live.partial = ""
            sentenceBuffer?.append(
                finalText: text, startSample: startSample, endSample: endSample
            )
            _ = lang
        }
    }
}
