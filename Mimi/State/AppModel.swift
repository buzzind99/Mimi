import AVFoundation
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
    @Published var apps: [TargetApp] = []
    @Published var selectedApp: TargetApp?
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

    private var capture: ProcessTapCapture?
    private var engine: Transcriber?
    private var sentenceBuffer: SentenceBuffer?
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var watchdogTimer: Timer?
    private var sessionStartedAt: Date?
    private var sessionMetadata: SessionMetadata?
    private var cancellables = Set<AnyCancellable>()

    init() {
        Task { [translationQueue] in
            await translationQueue.setHandlers(
                result: { [weak self] index, translation in
                    Task { @MainActor in
                        self?.applyTranslation(index: index, translation: translation)
                    }
                },
                status: { [weak self] status in
                    Task { @MainActor in
                        self?.translationStatus = status
                    }
                })
        }
        refreshModelAvailability()
        refreshApps()

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

    func refreshApps() {
        apps = ProcessScanner.pickableApps()
        if let selectedApp, !apps.contains(selectedApp) {
            self.selectedApp = nil
        }
    }

    // MARK: - Session control

    func start() {
        guard case .idle = phase else { return }
        guard let app = selectedApp else {
            errorMessage = "Choose the app whose audio to capture (e.g. your browser)."
            return
        }
        phase = .starting
        errorMessage = nil

        Task { @MainActor in
            do {
                try await self.beginSession(app: app)
            } catch {
                self.phase = .failed(error.localizedDescription)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func beginSession(app: TargetApp) async throws {
        // Microphone permission (TCC) covers process-tap capture.
        let granted = await Self.requestMicPermission()
        guard granted else { throw CaptureError.permissionDenied }

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

        let buffer = SentenceBuffer()
        buffer.onSentence = { [weak self] sentence in
            Task { @MainActor in self?.handleSentence(sentence) }
        }
        sentenceBuffer = buffer

        let capture = ProcessTapCapture()
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
                    "silent=\(chunk.silent) t=\(SessionClock.timestamp(SessionClock.seconds(chunk.startSample)))")
            }
            #endif
            let pushed = chunk.startSample + chunk.samples.count
            Task { @MainActor in
                self.latencySeconds = max(0, Double(pushed - engine.processedSamples) / SessionClock.sampleRate)
            }
        }
        self.capture = capture

        let pids = ProcessScanner.tapPIDs(for: app)
        try capture.start(pids: pids)

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
        // pack the first time).
        await translationQueue.resetForRetry()
        translationConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: "en"))

        startTimers()
    }

    func stop() {
        guard phase == .running || phase == .sourceLost else { return }
        phase = .stopping

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

        // Flush a partially-formed sentence, then wind translation down.
        sentenceBuffer?.flush()
        sentenceBuffer = nil
        translationConfig = nil
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
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdog() }
        }
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
    }

    private func pollASR() {
        guard let engine else { return }
        while let event = engine.poll() {
            handleASREvent(event)
        }
    }

    private func watchdog() {
        guard case .running = phase, let capture, let app = selectedApp else { return }
        let current = capture.currentPIDs
        let dead = current.filter { !ProcessScanner.isAlive($0) }
        if !dead.isEmpty {
            let fresh = ProcessScanner.tapPIDs(for: app)
            if ProcessScanner.isAlive(app.pid) {
                if Set(fresh) != Set(current), !fresh.isEmpty {
                    try? capture.retarget(pids: fresh)
                    phase = .running
                }
            } else {
                phase = .sourceLost
            }
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
        Task { await translationQueue.enqueue(sentence) }
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

    // MARK: - Permissions

    private static func requestMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
