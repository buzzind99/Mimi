import AppKit
import Foundation
import Observation
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

/// Which translation engine is currently attached to the queue. Derived
/// state (status pill, Settings "Currently using" row) reads this, never the
/// provider picker — a provider change applies on the next session start or
/// manual retry.
enum ActiveTranslationEngine: Equatable {
    case apple
    case external
}

/// Orchestrates capture → ASR → sentence buffering → translation, and owns
/// the published UI state. All public state is @MainActor. The mechanics of
/// a live session (engine, capture, buffering, timers) live in
/// `SessionController`.
@Observable
@MainActor
final class AppModel {
    // Observed UI state
    var phase: SessionPhase = .idle
    var entries: [SessionEntry] = []
    var translationStatus: TranslationStatus = .idle
    var engineIsMock = false
    var modelURL: URL?
    var hudVisible = false
    /// HUD translation history cursor: the pinned sentence index while
    /// browsing older translations, or nil to follow the latest translated
    /// entry. Pinning an older entry means new translations never move the
    /// view; nil tracks the newest.
    var hudPinnedIndex: Int?
    var errorMessage: String?
    /// True while a session start is blocked on the first-launch dictionary
    /// build (see `ensureDictionaryReady`) so the status bar can show
    /// "Building dictionary…" instead of "Starting…".
    private(set) var isPreparingDictionary = false
    /// True while model discovery (resolve + SHA-256 verify) is in flight —
    /// at launch and on a Settings re-check. Start is gated on it: the
    /// verify hashes up to ~200 MB and must never run on the main thread.
    private(set) var isCheckingModel = true

    /// Drives SwiftUI's `.translationTask` (session acquisition + pack prompt).
    var translationConfig: TranslationSession.Configuration?

    /// Launch-time model discovery, spawned async in `init` (the verify is a
    /// multi-hundred-MB hash and must not stall the first frame). Internal so
    /// tests can await it before asserting on phase state.
    private(set) var initialModelCheck: Task<Void, Never>?

    let live = LivePartialState()
    let latency = LatencyState()
    let translationQueue = TranslationQueue()
    /// Non-secret translation provider settings (selected provider, hasKey
    /// flags, OpenRouter model, test results). Keys stay in `SecureKeyStoring`
    /// and are read only when an engine is constructed.
    let translationSettings: TranslationSettings

    /// True once this session has latched onto Apple on-device after an
    /// external engine failed (the Settings "Currently using" row surfaces it).
    var translationFallbackActive = false

    /// The engine currently attached to the queue — Apple's via the hidden
    /// `.translationTask` host, an external one via `translationWorker`.
    private(set) var activeTranslationEngine: ActiveTranslationEngine = .apple

    /// The spawned external-engine worker (`queue.run(with:)`). Apple runs
    /// belong to SwiftUI's `.translationTask` instead. Torn down on stop.
    private var translationWorker: Task<Void, Never>?

    /// Injectable HTTP transport for the external engines (tests); nil drives
    /// the real per-provider `URLSession` transports.
    let translationTransport: HTTPTranslationTransport?

    /// Internal (not private) so tests can drive the session callbacks.
    let sessionController: SessionController

    /// `makeSessionController` is injectable so tests can drive the start/
    /// stop flow over a scripted `SessionController` (no TCC prompt, no SCK,
    /// no native runtime); nil (the default) builds the real one — no
    /// behavior change.
    /// Injectable so tests can quiesce the launch check (stub `resolve`):
    /// the real locator SHA-256-verifies up to ~200 MB and its success feeds
    /// the engine warm-up — real blocking work tests must never trigger.
    init(
        makeSessionController: (
            (LivePartialState, LatencyState, TranslationQueue) -> SessionController
        )? = nil,
        translationSettings: TranslationSettings? = nil,
        translationTransport: HTTPTranslationTransport? = nil,
        initialModelResolve: @escaping @Sendable () -> URL? = { ModelLocator.resolve() }
    ) {
        self.translationSettings = translationSettings ?? TranslationSettings()
        self.translationTransport = translationTransport
        if let makeSessionController {
            sessionController = makeSessionController(live, latency, translationQueue)
        } else {
            sessionController = SessionController(
                live: live, latency: latency, translationQueue: translationQueue
            )
        }
        wireSessionController()
        translationQueue.setHandlers(
            result: { [weak self] index, translation in
                self?.applyTranslation(index: index, translation: translation)
            },
            status: { [weak self] status in
                self?.handleTranslationStatus(status)
            }
        )
        initialModelCheck = Task { await refreshModelAvailability(resolve: initialModelResolve) }
        prepareDictionaryIfNeeded()

        NotificationCenter.default.addObserver(
            forName: .mimiAppWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    private func wireSessionController() {
        sessionController.onSessionBegin = { [weak self] in
            guard let self else { return }
            entries.removeAll()
            hudPinnedIndex = nil
            // The Apple-fallback latch is per session: a fresh session
            // re-attempts the configured provider from scratch.
            translationFallbackActive = false
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

    /// Re-checks the model location and moves `idle`↔`needsModel` accordingly.
    /// The resolve (existence + SHA-256 verify, hashing up to ~200 MB) runs
    /// off-main and the result is hopped back here; `isCheckingModel` gates
    /// Start while the check is in flight. `resolve` is injectable for tests;
    /// the default drives the real locator.
    func refreshModelAvailability(
        resolve: @escaping @Sendable () -> URL? = { ModelLocator.resolve() }
    ) async {
        isCheckingModel = true
        let url = await Task.detached(priority: .userInitiated) { resolve() }.value
        modelURL = url
        if url == nil, phase == .idle {
            phase = .needsModel
        } else if url != nil, phase == .needsModel {
            phase = .idle
        }
        sessionController.warmUpIfNeeded(modelURL: url)
        isCheckingModel = false
    }

    // MARK: - Dictionary preparation

    /// Kicks the first-launch dictionary preparation (bundled `system.dic.zst`
    /// → decompressed dictionary, see `DictionaryStore`) in the background so
    /// ruby annotations come up soon after startup. Purely opportunistic:
    /// until it succeeds (or if it never does) text renders unannotated, so
    /// failures are logged only and retried on the next launch.
    /// `resolve`/`prepare` are injectable for tests; the defaults drive the
    /// real store.
    func prepareDictionaryIfNeeded(
        resolve: () -> URL? = { DictionaryStore.resolve() },
        prepare: ((@escaping @Sendable (Result<URL, Error>) -> Void) -> Void) = {
            DictionaryStore.shared.prepare(completion: $0)
        }
    ) {
        guard resolve() == nil else { return }
        prepare { result in
            if case let .failure(error) = result {
                print(
                    "[dictionary] first-launch build failed; text stays unannotated: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Session-start gate: a session must never run while furigana is
    /// silently missing, so a missing database is built before capture
    /// begins. The launch-time kick (`prepareDictionaryIfNeeded`, above)
    /// usually finishes the build first; this coalesces behind an in-flight
    /// build on the store's queue and only blocks when none is running.
    /// A failed build throws so the start fails visibly in the status bar
    /// (pressing Start again retries). `resolve`/`prepare` are injectable
    /// for tests; the defaults drive the real store's async surface.
    func ensureDictionaryReady(
        resolve: () -> URL? = { DictionaryStore.resolve() },
        prepare: (() async throws -> URL)? = nil
    ) async throws {
        guard resolve() == nil else { return }
        isPreparingDictionary = true
        defer { isPreparingDictionary = false }
        _ = try await(prepare ?? DictionaryStore.shared.prepare)()
    }

    // MARK: - Session control

    func start() {
        guard case .idle = phase, !isCheckingModel else { return }
        phase = .starting
        errorMessage = nil

        Task { @MainActor in
            do {
                try await self.ensureDictionaryReady()
                try await self.beginSession()
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func beginSession() async throws {
        let started = try await sessionController.begin(modelURL: modelURL)
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

        // Activate translation: an external provider's worker is spawned
        // directly; Apple goes through the hidden `.translationTask` host
        // (prompting for the language pack the first time). Invalidate the
        // config first (mirroring retryTranslation) so SwiftUI reliably
        // re-fires the task even if a config survived.
        translationQueue.resetForRetry()
        activateTranslation()

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
        // The external worker parks in the queue's wake loop after draining;
        // once `sessionController.stop()` has drained (translations intact),
        // tear it down. Apple runs are owned by SwiftUI and stay parked.
        translationWorker?.cancel()
        translationWorker = nil
        translationStatus = .idle
        phase = .idle
    }

    /// Retry after a translation failure (status-bar button). Re-reads the
    /// selected provider (and its key) and re-attaches an engine — so a
    /// manual retry re-attempts the external engine even after the fallback
    /// latched, in case the key or network was fixed. The latch itself is
    /// one-way per session: a second external failure stays `.unavailable`
    /// with this same button for recovery.
    func retryTranslation() {
        // A stale note (e.g. "…has no API key") must not outlive the retry:
        // `activateTranslation` re-sets it when still unconfigured.
        errorMessage = nil
        activateTranslation()
    }

    /// Attaches the selected provider's engine to the queue. Called on
    /// session start and on `retryTranslation` — a provider change therefore
    /// applies no later than the next session start.
    ///
    /// External path: build the engine (key read from the Keychain here, at
    /// construction), spawn the worker task, park the Apple host by
    /// invalidating any live config. Apple path: invalidate + recreate the
    /// config so `.translationTask` reliably re-fires and hands an
    /// `AppleSessionEngine` to `queue.run(with:)`.
    private func activateTranslation() {
        if let engine = makeExternalEngine() {
            activeTranslationEngine = .external
            translationConfig?.invalidate()
            translationWorker?.cancel()
            let queue = translationQueue
            translationWorker = Task {
                await queue.run(with: engine)
            }
        } else {
            if translationSettings.selectedProvider.isExternal {
                // Selected but unconfigured (key deleted): degrade to Apple
                // with a status note instead of failing outright. Dev builds
                // use a no-op key store (see `TranslationSettings.init`), so
                // the note explains the dev pin instead of a missing key.
                #if DEBUG
                    errorMessage =
                        "Dev build uses Apple on-device translation — external providers are disabled."
                #else
                    errorMessage =
                        "\(translationSettings.selectedProvider.displayName) has no API key — using Apple on-device."
                #endif
            }
            activeTranslationEngine = .apple
            translationConfig?.invalidate()
            translationConfig = makeTranslationConfig()
        }
    }

    /// Builds the selected external provider's engine, or nil when Apple is
    /// selected (or the external provider has no usable key — the unconfigured
    /// edge falls back to Apple with a note in `activateTranslation`).
    private func makeExternalEngine() -> (any TranslationEngine)? {
        let provider = translationSettings.selectedProvider
        guard provider.isExternal, let key = translationSettings.key(for: provider) else {
            return nil
        }
        // The guard narrowed the domain to the external providers; Apple is
        // served by the `.translationTask` host in `activateTranslation`.
        var engine: any TranslationEngine
        if provider == .google {
            engine = GoogleTranslateEngine(apiKey: key, transport: translationTransport)
        } else if provider == .deepl {
            engine = DeepLEngine(apiKey: key, transport: translationTransport)
        } else {
            engine = OpenRouterEngine(
                apiKey: key,
                model: translationSettings.openRouterModel,
                transport: translationTransport
            )
        }
        let queue = translationQueue
        engine.onRetry = { progress in
            Task { @MainActor in queue.noteRetry(progress) }
        }
        return engine
    }

    /// Routes queue status updates to the published state and drives the
    /// latched Apple fallback. When an external engine exhausts its retries
    /// (`.unavailable`) and the fallback hasn't engaged this session,
    /// invalidate + recreate `translationConfig` — the hidden
    /// `TranslationSessionHost` fires, hands an `AppleSessionEngine` to
    /// `queue.run(with:)`, the generation token retires the dead external
    /// run, and the surviving `pending` replays onto Apple. Internal so tests
    /// can drive the queue's status callback directly.
    func handleTranslationStatus(_ status: TranslationStatus) {
        translationStatus = status
        guard case .unavailable = status,
              activeTranslationEngine == .external,
              !translationFallbackActive
        else { return }
        translationFallbackActive = true
        fallBackToApple()
    }

    /// The one-way latch: once on Apple for the rest of the session (no
    /// periodic re-probing). Publishes `.degraded` so the footer explains the
    /// switch; the fresh Apple run publishes `.ready` over it once flowing.
    private func fallBackToApple() {
        activeTranslationEngine = .apple
        translationStatus = .degraded("External translation failed — using Apple on-device")
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

    /// Copies the plain-text transcript to the pasteboard; shared by the
    /// ⌘⇧C command and the export menu.
    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportText(), forType: .string)
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
