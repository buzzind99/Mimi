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
    /// True while a session start is blocked on the first-launch dictionary
    /// build (see `ensureDictionaryReady`) so the status bar can show
    /// "Building dictionary…" instead of "Starting…".
    private(set) var isPreparingDictionary = false
    /// True while model discovery (resolve + SHA-256 verify) is in flight —
    /// at launch and on a Settings re-check. Start is gated on it: the
    /// verify hashes up to ~1.2 GB and must never run on the main thread.
    private(set) var isCheckingModel = true

    /// Drives SwiftUI's `.translationTask` (session acquisition + pack prompt).
    var translationConfig: TranslationSession.Configuration?

    /// Launch-time model discovery, spawned async in `init` (the verify is a
    /// multi-hundred-MB hash and must not stall the first frame). Internal so
    /// tests can await it before asserting on phase state.
    private(set) var initialModelCheck: Task<Void, Never>?

    /// The model resolver driving every availability refresh (launch check,
    /// selection re-resolve, Settings re-check). Injectable for tests; the
    /// default drives the real locator.
    private let modelResolve: @Sendable (ASRModelChoice) -> URL?

    let live = LivePartialState()
    let latency = LatencyState()
    let audioLevel = AudioLevelState()
    /// Toast stack: every error surface routes through here;
    /// cleared on session stop/teardown.
    let toasts = ToastCenter()
    let translationQueue = TranslationQueue()
    /// Non-secret translation provider settings (selected provider, hasKey
    /// flags, OpenRouter model, test results). Keys stay in `SecureKeyStoring`
    /// and are read only when an engine is constructed.
    let translationSettings: TranslationSettings
    /// Non-secret ASR model selection (Lite default, Full opt-in); persisted
    /// across launches. Switching applies at the next session start.
    let asrModelSettings: ASRModelSettings

    /// Latest resolve result per choice (bundled → downloaded → dev, SHA-256
    /// verified). The Settings Model section reads it to enable selection;
    /// `modelURL` is the active choice's entry.
    private(set) var modelAvailability: [ASRModelChoice: URL] = [:]

    /// True once this session has latched onto Apple on-device after an
    /// external engine failed (the Settings "Currently using" row surfaces it).
    /// Reset by every manual retry (each retry re-arms the one-way fallback).
    var translationFallbackActive = false

    /// The engine currently attached to the queue — Apple's via the hidden
    /// `.translationTask` host, an external one via `translationWorker`.
    /// Internal: the translation-engine management lives in
    /// `AppModelTranslation.swift` (file split for the lint gate).
    var activeTranslationEngine: ActiveTranslationEngine = .apple

    /// The refresh spawned by the most recent `selectModel` (tracked so
    /// `adoptDownloadedModel` can await it instead of stacking passes).
    private var modelSelectionRefresh: Task<Void, Never>?

    /// The spawned external-engine worker (`queue.run(with:)`). Apple runs
    /// belong to SwiftUI's `.translationTask` instead. Torn down on stop.
    /// Internal: managed from `AppModelTranslation.swift`.
    var translationWorker: Task<Void, Never>?

    /// The in-flight teardown task from `stop()`. `shutdownForTermination`
    /// awaits it so quit never runs a second teardown concurrently with a
    /// user-initiated one.
    private var stopTask: Task<Void, Never>?

    /// Latched by `shutdownForTermination`: once quit-time teardown begins,
    /// `start` is refused — a session begun during the `.terminateLater`
    /// window would race the engine retirement that follows the drain.
    private(set) var isTerminating = false
    /// SESSION-card duration anchors: set when a session's chunks start
    /// flowing (`onSessionBegin`) and when teardown completes
    /// (`performStop`); both nil before the first session. Duration reads
    /// now − startedAt while running, endedAt − startedAt after stop.
    private(set) var sessionStartedAt: Date?
    private(set) var sessionEndedAt: Date?
    /// When the capture source died mid-session (`.sourceLost`). The SESSION
    /// card freezes at it during the outage — the session clock itself
    /// survives a successful restart, so duration resumes counting then.
    private(set) var captureLostAt: Date?
    /// Injectable so tests can observe (and fake) the quit-time release of
    /// the process-warm ASR engine; the default drives the real factory.
    private let retireWarmEngine: @Sendable () -> Void

    /// Injectable HTTP transport for the external engines (tests); nil drives
    /// the real per-provider `URLSession` transports.
    let translationTransport: HTTPTranslationTransport?

    /// Injectable so the terminate-notification wiring can be tested
    /// hermetically — posting on the shared `.default` center from a parallel
    /// test would stop every other live `AppModel`. The default is the
    /// app-wide center.
    private let willTerminateNotifications: NotificationCenter

    /// Internal (not private) so tests can drive the session callbacks.
    let sessionController: SessionController

    /// `makeSessionController` is injectable so tests can drive the start/
    /// stop flow over a scripted `SessionController` (no TCC prompt, no SCK,
    /// no native runtime); nil (the default) builds the real one — no
    /// behavior change.
    /// Injectable so tests can quiesce the launch check (stub `resolve`):
    /// the real locator SHA-256-verifies up to ~1.2 GB and its success feeds
    /// the engine warm-up — real blocking work tests must never trigger.
    init(
        makeSessionController: (
            (LivePartialState, LatencyState, AudioLevelState, TranslationQueue) -> SessionController
        )? = nil,
        translationSettings: TranslationSettings? = nil,
        asrModelSettings: ASRModelSettings? = nil,
        translationTransport: HTTPTranslationTransport? = nil,
        initialModelResolve: @escaping @Sendable (ASRModelChoice) -> URL? = {
            ModelLocator.resolve(for: $0)
        },
        retireWarmEngine: @escaping @Sendable () -> Void = {
            ASREngineFactory.retireWarmEngine()
        },
        willTerminateNotifications: NotificationCenter = .default
    ) {
        self.translationSettings = translationSettings ?? TranslationSettings()
        self.asrModelSettings = asrModelSettings ?? ASRModelSettings()
        modelResolve = initialModelResolve
        self.translationTransport = translationTransport
        self.retireWarmEngine = retireWarmEngine
        self.willTerminateNotifications = willTerminateNotifications
        if let makeSessionController {
            sessionController = makeSessionController(live, latency, audioLevel, translationQueue)
        } else {
            sessionController = SessionController(
                live: live, latency: latency, audioLevel: audioLevel,
                translationQueue: translationQueue
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
        initialModelCheck = Task { await refreshModelAvailability() }
        prepareDictionaryIfNeeded()

        willTerminateNotifications.addObserver(
            forName: .mimiAppWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.shutdownForTermination() }
        }
    }

    private func wireSessionController() {
        sessionController.onSessionBegin = { [weak self] in
            guard let self else { return }
            entries.removeAll()
            hudPinnedIndex = nil
            sessionStartedAt = Date()
            sessionEndedAt = nil
            captureLostAt = nil
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
            // Throttled ASR warnings (first + every 32nd): transient toast.
            self?.toasts.post(
                key: ToastKey.asrWarning, style: .yellowAuto,
                title: "Transcription warning", body: message
            )
        }
        sessionController.onCaptureError = { [weak self] message in
            // A capture failure is fatal in any active phase: mid-session it
            // means the source is gone; during `.starting` it means the
            // session can never come up, so surface it instead of swallowing.
            guard let self, phase == .running || phase == .starting else { return }
            phase = .sourceLost
            captureLostAt = Date()
            postCaptureLost(body: message)
        }
    }

    /// The `capture.lost` red card with the Restart-capture fix action;
    /// re-posted (deduped in place) when a restart fails.
    private func postCaptureLost(body: String) {
        toasts.post(
            key: ToastKey.captureLost, style: .redPersistent,
            title: "Capture lost", body: body,
            action: ToastCenter.Action(
                label: "Restart capture",
                handler: { [weak self] in self?.restartCapture() }
            )
        )
    }

    // MARK: - Model / app discovery

    /// Re-checks both model locations and moves `idle`↔`needsModel` by the
    /// active choice's result. The resolve (existence + SHA-256 verify,
    /// hashing up to ~1.2 GB) runs off-main and the result is hopped back
    /// here; `isCheckingModel` gates Start while the check is in flight.
    /// `resolve` overrides the stored resolver for tests; by default the
    /// resolver injected at init drives the lookup. The active choice's URL
    /// also lands in `modelURL` and every choice's result in
    /// `modelAvailability` (Settings rows).
    func refreshModelAvailability(
        resolve: (@Sendable (ASRModelChoice) -> URL?)? = nil
    ) async {
        let resolve = resolve ?? modelResolve
        isCheckingModel = true
        let selected = asrModelSettings.selected
        let resolved = await Task.detached(priority: .userInitiated) { () -> [ASRModelChoice: URL] in
            // Both choices resolve concurrently: each verify hashes up to
            // ~1.2 GB, and parallel keeps the wall time at the slower one
            // instead of the sum.
            await withTaskGroup(of: (ASRModelChoice, URL?).self) { group in
                for choice in ASRModelChoice.allCases {
                    group.addTask { (choice, resolve(choice)) }
                }
                var availability: [ASRModelChoice: URL] = [:]
                for await(choice, url) in group {
                    availability[choice] = url
                }
                return availability
            }
        }.value
        modelAvailability = resolved
        let url = resolved[selected]
        modelURL = url
        if url == nil, phase == .idle {
            phase = .needsModel
        } else if url != nil, phase == .needsModel {
            phase = .idle
        }
        sessionController.warmUpIfNeeded(modelURL: url)
        isCheckingModel = false
    }

    // MARK: - Model selection

    /// Switches the active ASR model. Only a downloaded + verified model can
    /// be selected (its resolve result must be cached), and a running or
    /// starting session must never be re-modelled mid-flight — the change
    /// applies at the next session start, like the translation provider.
    /// Persisting re-resolves (updating `modelURL` and `phase`) and re-warms
    /// the new engine in the background (`warmUpIfNeeded` re-arms on the new
    /// path).
    func selectModel(_ choice: ASRModelChoice) {
        guard phase != .running, phase != .starting else { return }
        guard modelAvailability[choice] != nil else { return }
        asrModelSettings.select(choice)
        modelSelectionRefresh = Task { await refreshModelAvailability() }
    }

    /// Called after a Settings download of `choice` completes (the download
    /// button is explicit intent): re-resolves availability so the new file
    /// is hashed + verified, then auto-selects it.
    func adoptDownloadedModel(_ choice: ASRModelChoice) async {
        await refreshModelAvailability()
        selectModel(choice)
        // `selectModel` re-resolves in a tracked task; awaiting it here (one
        // extra pass, never overlapping `refreshModelAvailability`) means the
        // new model is live (modelURL + warm-up) before we return.
        await modelSelectionRefresh?.value
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
        guard !isCheckingModel, !isTerminating else { return }
        // A failed session restarts like an idle one (the sidebar offers
        // Start from `.failed`, and the failure card clears on the
        // next Start); every other active phase refuses.
        switch phase {
        case .idle, .failed: break
        default: return
        }
        phase = .starting
        // "Cleared on next Start": a previous session's failure card must
        // not outlive the user pressing Start again.
        toasts.dismiss(key: ToastKey.sessionFailed)

        Task { @MainActor in
            do {
                try await self.ensureDictionaryReady()
                try await self.beginSession()
            } catch {
                self.phase = .failed(error.localizedDescription)
                // Freeze the SESSION duration at the failure: a capture that
                // died mid-start would otherwise leave the endedAt anchor nil
                // and the frozen path reading now − startedAt per render.
                self.sessionEndedAt = Date()
                self.toasts.post(
                    key: ToastKey.sessionFailed, style: .redPersistent,
                    title: "Session failed", body: error.localizedDescription
                )
            }
        }
    }

    private func beginSession() async throws {
        let started = try await sessionController.begin(
            modelURL: modelURL, modelID: asrModelSettings.selected.modelID
        )
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
        // A source-lost card cannot survive into the session it restarted
        // (the restart path also clears it; this covers a fresh start).
        toasts.dismiss(key: ToastKey.captureLost)

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

        stopTask = Task { @MainActor in
            await performStop()
            stopTask = nil
        }
    }

    /// Quit-time teardown, invoked via `.mimiAppWillTerminate` (posted by
    /// `AppDelegate.applicationShouldTerminate`, which returns
    /// `.terminateLater` and waits for `.mimiTerminationTeardownComplete`).
    ///
    /// Winds a live session down exactly like a manual stop — flush decode +
    /// translation tail stay exportable — then permanently releases the
    /// process-warm ASR engine so the C library frees its session (and its
    /// Metal contexts) before the process exits instead of leaving them alive
    /// at device teardown. Completes with the teardown-complete notification
    /// in all paths, including an idle model (the warm engine can exist with
    /// no session ever started), latching `isTerminating` first.
    func shutdownForTermination() async {
        isTerminating = true
        if let stopTask {
            await stopTask.value
        } else if phase == .starting || phase == .running || phase == .stopping || phase == .sourceLost {
            phase = .stopping
            await performStop()
        }
        retireWarmEngine()
        NotificationCenter.default.post(name: .mimiTerminationTeardownComplete, object: nil)
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
        sessionEndedAt = Date()
        // Stop/teardown clears all toasts (phase → `.idle`).
        toasts.clearAll()
        phase = .idle
    }

    /// Restarts the capture stream mid-session — the `capture.lost` toast's
    /// fix action. Guarded on `.sourceLost`: a
    /// double-tap is a no-op and a `stop()` during the restart wins the race
    /// (the phase check after the await refuses to resurrect a stopped
    /// session). Entries, the session clock, and the fallback latch survive;
    /// `onSessionBegin` does not re-fire.
    func restartCapture() {
        guard phase == .sourceLost else { return }
        phase = .starting
        Task { @MainActor in
            do {
                try await sessionController.restartCapture()
                // A stop() interleaved while the restart was in flight: the
                // session is gone (engine nil, restartCapture no-oped) and
                // must not come back up.
                guard phase == .starting else { return }
                phase = .running
                captureLostAt = nil
                toasts.dismiss(key: ToastKey.captureLost)
            } catch {
                guard phase == .starting else { return }
                phase = .sourceLost
                postCaptureLost(body: "Restart failed: \(error.localizedDescription)")
            }
        }
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

    /// SESSION-card character total: Σ sentence text lengths.
    var sessionCharacterCount: Int {
        entries.reduce(0) { $0 + $1.sentence.text.count }
    }
}
