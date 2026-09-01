import Foundation

/// Owns the mechanics of a live capture → ASR session: engine lifecycle and
/// warm-up scheduling, system-audio capture wiring, sentence buffering, and
/// the poll/tick timers. Published UI state, translation configuration, and
/// export delegation stay in `AppModel`, which plugs in via the callbacks.
@MainActor
final class SessionController {
    private let live: LivePartialState
    private let latency: LatencyState
    private let translationQueue: TranslationQueue
    private let makeEngine: (URL?, Bool) -> ASREngine?
    private let makeCapture: () -> any AudioCapturing
    private let ensurePermission: () async -> Bool

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
    /// Guards the one-shot engine warm-up (app launch / model arrival).
    private var warmUpScheduled = false
    #if DEBUG
        private var debugIngressChunks = 0
    #endif

    /// Injection seams for tests: engine, capture, and permission default to
    /// the real implementations; tests inject doubles so `begin()` and the
    /// event paths run without TCC, ScreenCaptureKit, or the native runtime.
    /// `makeEngine` receives `allowMock` (true from `begin`, false from the
    /// warm-up, which must never fall back to the mock).
    init(
        live: LivePartialState,
        latency: LatencyState,
        translationQueue: TranslationQueue,
        makeEngine: @escaping (URL?, Bool) -> ASREngine? = {
            ASREngineFactory.makeEngine(modelURL: $0, allowMock: $1)
        },
        makeCapture: @escaping () -> any AudioCapturing = { SystemAudioCapture() },
        ensurePermission: @escaping () async -> Bool = {
            await SystemAudioCapture.ensurePermission()
        }
    ) {
        self.live = live
        self.latency = latency
        self.translationQueue = translationQueue
        self.makeEngine = makeEngine
        self.makeCapture = makeCapture
        self.ensurePermission = ensurePermission
    }

    // MARK: - Warm-up

    /// Loads the ASR model + compiles the Metal pipelines in the background
    /// (at app launch, or once a model becomes available) so the first
    /// session start is instant. Safe against racing `begin`: the engine's
    /// `prepare` is serialized, and a second opener reuses the already-open
    /// session.
    func warmUpIfNeeded(modelURL: URL?) {
        guard !warmUpScheduled, let url = modelURL else { return }
        warmUpScheduled = true
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
    /// permission or capture setup fails.
    func begin() async throws -> Bool {
        // Screen Recording permission (TCC) covers SCK system-audio capture.
        guard await ensurePermission() else {
            throw CaptureError.permissionDenied
        }

        let modelURL = ModelLocator.resolve()
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
        capture.onChunk = { [weak self] chunk in
            guard let self, let engine = self.engine else { return }
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

        try engine.prepare()
        try engine.openStream()

        sessionMetadata = SessionMetadata(
            startedAt: Date(),
            sourceLang: "ja",
            targetLang: "en",
            model: engine.isMock ? "mock" : ModelLocator.modelID,
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
        // Strictly ordered teardown: capture stops first, then the ASR
        // finish → drain on the ASR queue.
        capture?.stop()
        if let engine {
            let drained = engine.finish()
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
        _ = await translationQueue.drain(timeout: 5)
        live.partial = ""
    }

    // MARK: - Capture (ASR queue)

    private func handleCaptureChunk(_ chunk: AudioChunk, engine: ASREngine) {
        engine.push(chunk.samples)
        #if DEBUG
            logIngressEnergy(chunk)
        #endif
        let pushed = chunk.startSample + chunk.samples.count
        Task { @MainActor in
            self.latency.update(
                max(0, Double(pushed - engine.processedSamples) / SessionClock.sampleRate)
            )
        }
    }

    #if DEBUG
        /// Every ~8 s of audio, print ASR-ingress energy so a dead pipeline
        /// (all-zero audio reaching the model) is obvious.
        private func logIngressEnergy(_ chunk: AudioChunk) {
            debugIngressChunks += 1
            guard debugIngressChunks % 50 == 0 else { return }
            var energy: Float = 0
            for s in chunk.samples {
                energy += s * s
            }
            let rms = (energy / Float(max(1, chunk.samples.count))).squareRoot()
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
