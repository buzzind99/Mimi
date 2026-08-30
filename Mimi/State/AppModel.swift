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
/// the published UI state. All public state is @MainActor. The mechanics of
/// a live session (engine, capture, buffering, timers) live in
/// `SessionController`.
@MainActor
final class AppModel: ObservableObject {
    // Published UI state
    @Published var phase: SessionPhase = .idle
    @Published var entries: [SessionEntry] = []
    @Published var translationStatus: TranslationStatus = .idle
    @Published var engineIsMock = false
    @Published var modelURL: URL?
    @Published var hudVisible = false
    /// HUD translation history cursor: the pinned sentence index while
    /// browsing older translations, or nil to follow the latest translated
    /// entry. Pinning an older entry means new translations never move the
    /// view; nil tracks the newest.
    @Published var hudPinnedIndex: Int?
    @Published var errorMessage: String?

    /// Drives SwiftUI's `.translationTask` (session acquisition + pack prompt).
    @Published var translationConfig: TranslationSession.Configuration?

    let live = LivePartialState()
    let latency = LatencyState()
    let translationQueue = TranslationQueue()

    /// Internal (not private) so tests can drive the session callbacks.
    let sessionController: SessionController

    init() {
        sessionController = SessionController(
            live: live, latency: latency, translationQueue: translationQueue
        )
        wireSessionController()
        translationQueue.setHandlers(
            result: { [weak self] index, translation in
                self?.applyTranslation(index: index, translation: translation)
            },
            status: { [weak self] status in
                self?.translationStatus = status
            }
        )
        refreshModelAvailability()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MimiAppWillTerminate"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    private func wireSessionController() {
        sessionController.onSessionBegin = { [weak self] in
            guard let self else { return }
            entries.removeAll()
            hudPinnedIndex = nil
        }
        sessionController.onEngineChosen = { [weak self] isMock, url in
            self?.engineIsMock = isMock
            self?.modelURL = url
        }
        sessionController.onSentence = { [weak self] sentence in
            self?.handleSentence(sentence)
        }
        sessionController.onEngineError = { [weak self] message in
            self?.errorMessage = message
        }
        sessionController.onCaptureError = { [weak self] message in
            // A capture failure is fatal in any active phase: mid-session it
            // means the source is gone; during `.starting` it means the
            // session can never come up, so surface it instead of swallowing.
            guard let self, phase == .running || phase == .starting else { return }
            phase = .sourceLost
            errorMessage = message
        }
    }

    // MARK: - Model / app discovery

    func refreshModelAvailability() {
        modelURL = ModelLocator.resolve()
        if modelURL == nil, phase == .idle {
            phase = .needsModel
        } else if modelURL != nil, phase == .needsModel {
            phase = .idle
        }
        sessionController.warmUpIfNeeded(modelURL: modelURL)
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
            }
        }
    }

    private func beginSession() async throws {
        let started = try await sessionController.begin()
        // The session may have been cancelled (or its capture lost) while
        // `begin()` was in flight. Tear down whatever begin() brought up so
        // a stopped session cannot come up anyway.
        guard phase == .starting else {
            await sessionController.stop()
            if phase == .stopping {
                phase = .idle
            }
            return
        }
        guard started else {
            phase = .needsModel
            return
        }

        phase = .running

        // Activate translation: the hidden `.translationTask` host picks this
        // up and hands a session to the queue (prompting for the language
        // pack the first time). Invalidate first (mirroring retryTranslation)
        // so SwiftUI reliably re-fires the task even if a config survived.
        translationQueue.resetForRetry()
        translationConfig?.invalidate()
        translationConfig = makeTranslationConfig()

        sessionController.startTimers()
    }

    func stop() {
        // `.starting` is stoppable too: begin() is a multi-await operation
        // (TCC prompt, capture, engine), and a session the user cancels
        // mid-start must never come up afterwards.
        guard phase == .starting || phase == .running || phase == .sourceLost else { return }
        phase = .stopping

        Task { @MainActor in
            await performStop()
        }
    }

    /// Teardown via `SessionController` (capture, ASR, buffering, timers),
    /// after which the translation queue has drained and the session winds
    /// down. That keeps the tail of the session exportable with translations
    /// intact.
    ///
    /// The translation config is deliberately left alive: once drained, the
    /// worker is suspended harmlessly, and keeping the config non-nil lets
    /// `beginSession` restart via the reliable invalidate + reassign path
    /// (same as `retryTranslation`). Nil-ing here and reassigning an
    /// identical config on start is a path SwiftUI's `.translationTask`
    /// does not reliably re-fire on.
    private func performStop() async {
        await sessionController.stop()
        translationStatus = .idle
        phase = .idle
    }

    func retryTranslation() {
        translationConfig?.invalidate()
        translationConfig = makeTranslationConfig()
    }

    /// ja→en configuration, built identically for session start and retry so
    /// SwiftUI's `.translationTask` treats both paths the same way.
    private func makeTranslationConfig() -> TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: "en")
        )
    }

    // MARK: - Event handling (main actor)

    private func handleSentence(_ sentence: Sentence) {
        entries.append(SessionEntry(sentence: sentence))
        // Synchronous main-actor enqueue: by the time `stop` drains, every
        // emitted sentence is observably in the queue.
        translationQueue.enqueue(sentence)
    }

    /// Internal (not private) so tests can exercise known/unknown indexes.
    func applyTranslation(index: Int, translation: SentenceTranslation) {
        if let at = entries.firstIndex(where: { $0.sentence.index == index }) {
            entries[at].appendTranslation(translation)
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
                entries: entries, metadata: sessionController.sessionMetadata, results: results
            )
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
