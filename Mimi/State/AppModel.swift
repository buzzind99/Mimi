import Combine
import Foundation
import Translation

/// Session lifecycle phases.
enum SessionPhase: Equatable {
    case needsModel
    case idle
    case starting
    case running
    case sourceLost
    case stopping
    case failed(String)
}

/// Orchestrates capture → ASR → sentence buffering → translation, and owns
/// the published UI state. All public state is @MainActor.
@MainActor
final class AppModel: ObservableObject {
    // Published UI state
    @Published var phase: SessionPhase = .idle
    @Published var entries: [SessionEntry] = []
    @Published var translationStatus: TranslationStatus = .idle
    @Published var latencySeconds: Double = 0
    @Published var engineIsMock = false
    @Published var modelURL: URL?
    @Published var hudVisible = false
    @Published var errorMessage: String?

    /// Drives SwiftUI's `.translationTask` (session acquisition + pack prompt).
    @Published var translationConfig: TranslationSession.Configuration?

    let live = LivePartialState()
    let translationQueue = TranslationQueue()

    private var capture: SystemAudioCapture?
    private var engine: Transcriber?
    private var sentenceBuffer: SentenceBuffer?
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var sessionStartedAt: Date?
    private var sessionMetadata: SessionMetadata?
    private var cancellables = Set<AnyCancellable>()

    init() {
        translationQueue.setHandlers(
            result: { [weak self] index, translation in
                self?.applyTranslation(index: index, translation: translation)
            },
            status: { [weak self] status in
                self?.translationStatus = status
            })
        refreshModelAvailability()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MimiAppWillTerminate"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    // MARK: - Model / app discovery

    func refreshModelAvailability() {
        modelURL = ModelLocator.resolve()
        if case .needsModel = phase { return }
        if modelURL == nil && phase == .idle {
            phase = .needsModel
        } else if modelURL != nil, phase == .needsModel {
            phase = .idle
        }
    }

    // MARK: - Session control

    func start() {
        guard case .idle = phase else { return }
        phase = .starting
        errorMessage = nil

        Task { @MainActor in
            do {
                try await self.beginSession()
            } catch {
                self.phase = .failed(error.localizedDescription)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func beginSession() async throws {
        // Screen Recording permission (TCC) covers SCK system-audio capture.
        guard await SystemAudioCapture.ensurePermission() else {
            throw CaptureError.permissionDenied
        }

        let modelURL = ModelLocator.resolve()
        guard let engine = ASREngineFactory.makeEngine(modelURL: modelURL, allowMock: true) else {
            phase = .needsModel
            return
        }
        self.engine = engine
        self.modelURL = modelURL
        engineIsMock = engine.isMock
        if let native = engine as? NativeASREngine {
            native.onPushError = { [weak self] _, message in
                Task { @MainActor in self?.errorMessage = message }
            }
        }

        entries.removeAll()
        live.partial = ""
        live.lastFinalJP = nil
        live.lastFinalEN = ""
        latencySeconds = 0
        translationQueue.clearResults()

        let buffer = SentenceBuffer()
        buffer.onSentence = { [weak self] sentence in
            self?.handleSentence(sentence)
        }
        sentenceBuffer = buffer

        let capture = SystemAudioCapture()
        capture.gateEnabled = false
        #if DEBUG
        var debugIngressChunks = 0
        #endif
        capture.onChunk = { [weak self] chunk in
            guard let self, let engine = self.engine else { return }
            engine.push(chunk.samples)
            #if DEBUG
            // Every ~8 s of audio, print ASR-ingress energy so a dead
            // pipeline (all-zero audio reaching the model) is obvious.
            debugIngressChunks += 1
            if debugIngressChunks % 50 == 0 {
                var energy: Float = 0
                for s in chunk.samples { energy += s * s }
                let rms = (energy / Float(max(1, chunk.samples.count))).squareRoot()
                print(
                    "[capture] chunk #\(debugIngressChunks) rms=\(String(format: "%.6f", rms)) " +
                    "silent=\(chunk.silent) streamSilent=\(self.capture?.isStreamSilent ?? false) " +
                    "t=\(SessionClock.timestamp(SessionClock.seconds(chunk.startSample)))")
            }
            #endif
            let pushed = chunk.startSample + chunk.samples.count
            Task { @MainActor in
                self.latencySeconds = max(0, Double(pushed - engine.processedSamples) / SessionClock.sampleRate)
            }
        }
        capture.onIOError = { [weak self] error in
            Task { @MainActor in
                guard self?.phase == .running else { return }
                self?.phase = .sourceLost
                self?.errorMessage = error.localizedDescription
            }
        }
        self.capture = capture

        #if DEBUG
        print("[session] start: whole-system SCK audio capture")
        #endif
        try await capture.start()

        try engine.prepare()
        try engine.openStream()

        sessionStartedAt = Date()
        sessionMetadata = SessionMetadata(
            startedAt: Date(),
            sourceLang: "ja",
            targetLang: "en",
            model: engine.isMock ? "mock" : ModelLocator.modelID,
            chunkMS: 160,
            streamOffset: nil)

        phase = .running

        // Activate translation: the hidden `.translationTask` host picks this
        // up and hands a session to the queue (prompting for the language
        // pack the first time). Invalidate first (mirroring retryTranslation)
        // so SwiftUI reliably re-fires the task even if a config survived.
        translationQueue.resetForRetry()
        translationConfig?.invalidate()
        translationConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: "en"))

        startTimers()
    }

    func stop() {
        guard phase == .running || phase == .sourceLost else { return }
        phase = .stopping

        Task { @MainActor in
            await performStop()
        }
    }

    /// Teardown, ordered so pending translations finish first: capture and
    /// ASR are shut down immediately, the final flushed sentence is enqueued,
    /// and only after the translation queue drains (bounded by a timeout)
    /// does the session wind down. That keeps the tail of the session
    /// exportable with translations intact.
    ///
    /// The translation config is deliberately left alive: once drained, the
    /// worker is suspended harmlessly, and keeping the config non-nil lets
    /// `beginSession` restart via the reliable invalidate + reassign path
    /// (same as `retryTranslation`). Nil-ing here and reassigning an
    /// identical config on start is a path SwiftUI's `.translationTask`
    /// does not reliably re-fire on.
    private func performStop() async {
        // Strictly ordered teardown: capture stops first, then the ASR
        // finish → drain → close → destroy on the ASR queue.
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
        translationStatus = .idle
        live.partial = ""
        phase = .idle
    }

    func retryTranslation() {
        translationConfig?.invalidate()
        translationConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: "en"))
    }

    func toggleHUD() {
        hudVisible.toggle()
    }

    // MARK: - Timers

    private func startTimers() {
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
        case .partial(let text):
            live.partial = text
        case .final(let text, let startSample, let endSample, let lang):
            live.partial = ""
            sentenceBuffer?.append(
                finalText: text, startSample: startSample, endSample: endSample)
            _ = lang
        }
    }

    private func handleSentence(_ sentence: Sentence) {
        entries.append(SessionEntry(sentence: sentence))
        live.lastFinalJP = sentence
        // Synchronous main-actor enqueue: by the time `stop` drains, every
        // emitted sentence is observably in the queue.
        translationQueue.enqueue(sentence)
    }

    private func applyTranslation(index: Int, translation: SentenceTranslation) {
        if let at = entries.firstIndex(where: { $0.sentence.index == index }) {
            entries[at].translations.append(translation)
        }
        if translation.lang == "en" || live.lastFinalEN.isEmpty {
            live.lastFinalEN = translation.text
        }
    }

    // MARK: - Export

    var isExportable: Bool {
        !entries.isEmpty
    }

    func exportText() -> String {
        SessionExporter.plainText(entries: entries)
    }

    func export(format: SessionExporter.Format) throws -> Data {
        switch format {
        case .txt:
            return Data(SessionExporter.plainText(entries: entries).utf8)
        case .srt:
            return Data(SessionExporter.subtitles(entries: entries, format: .srt).utf8)
        case .vtt:
            return Data(SessionExporter.subtitles(entries: entries, format: .vtt).utf8)
        case .json:
            let results = snapshotTranslationResults()
            return try SessionExporter.json(
                entries: entries, metadata: sessionMetadata, results: results)
        }
    }

    private func snapshotTranslationResults() -> [Int: SentenceTranslation] {
        var snapshot: [Int: SentenceTranslation] = [:]
        for entry in entries {
            if let translation = entry.translations.last {
                snapshot[entry.sentence.index] = translation
            }
        }
        return snapshot
    }
}
