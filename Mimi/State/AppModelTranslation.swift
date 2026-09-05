import Foundation
import Translation

/// Translation-engine management surface of `AppModel` (retry, provider
/// activation, queue-status handling, the latched Apple fallback, and the
/// translation toasts), split out to keep `AppModel.swift` under the 600-line
/// lint gate.
extension AppModel {
    /// Retry after a translation failure (the toast's Retry action). Re-reads
    /// the selected provider (and its key) and re-attaches an engine — so a
    /// manual retry re-attempts the external engine even after the fallback
    /// latched, in case the key or network was fixed. Resets the latch:
    /// every manual retry re-arms the one-way auto-fallback, so a
    /// failure after a retry re-latches onto Apple instead of parking on
    /// `.unavailable` forever.
    func retryTranslation() {
        translationFallbackActive = false
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
    func activateTranslation() {
        if let engine = makeExternalEngine() {
            activeTranslationEngine = .external
            translationConfig?.invalidate()
            translationWorker?.cancel()
            let queue = translationQueue
            translationWorker = Task {
                await queue.run(with: engine)
            }
        } else {
            // Apple path. A selected-but-unconfigured external provider (key
            // deleted) degrades to Apple here instead of failing outright —
            // the footer's `.degraded`/`.unavailable` statuses and the
            // engines card surface the state. Dev builds pin the key store
            // to a no-op (see `TranslationSettings.init`), so external
            // providers always take this path there.
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

    /// Routes queue status updates to the published state, reconciles the
    /// translation toasts, and drives the latched Apple
    /// fallback. When an external engine exhausts its retries
    /// (`.unavailable`) and the fallback hasn't engaged this session,
    /// invalidate + recreate `translationConfig` — the hidden
    /// `TranslationSessionHost` fires, hands an `AppleSessionEngine` to
    /// `queue.run(with:)`, the generation token retires the dead external
    /// run, and the surviving `pending` replays onto Apple. Internal so tests
    /// can drive the queue's status callback directly.
    func handleTranslationStatus(_ status: TranslationStatus) {
        translationStatus = status
        reconcileTranslationToasts(status)
        guard case let .unavailable(_, severity) = status,
              activeTranslationEngine == .external,
              !translationFallbackActive
        else { return }
        translationFallbackActive = true
        fallBackToApple(severity: severity)
    }

    /// Posts/clears the translation toasts on state change (post on entry,
    /// dismiss on exit): retry progress is transient; degraded/unavailable
    /// are persistent cards carrying Retry; both clear when the status moves
    /// on (`.ready` for the fallback latch, leaving `.unavailable` for the
    /// red card).
    private func reconcileTranslationToasts(_ status: TranslationStatus) {
        switch status {
        case let .retrying(message):
            toasts.post(
                key: ToastKey.translationRetry, style: .yellowAuto,
                title: "Translation retrying", body: message
            )
        case let .degraded(message, _):
            toasts.dismiss(key: ToastKey.translationUnavailable)
            toasts.post(
                key: ToastKey.translationFallback, style: .yellowPersistent,
                title: "Translation degraded", body: message,
                action: retryAction
            )
        case let .unavailable(message, _):
            toasts.dismiss(key: ToastKey.translationFallback)
            toasts.post(
                key: ToastKey.translationUnavailable, style: .redPersistent,
                title: "Translation unavailable", body: message,
                action: retryAction
            )
        case .ready:
            toasts.dismiss(key: ToastKey.translationFallback)
            toasts.dismiss(key: ToastKey.translationUnavailable)
        case .translating, .idle:
            toasts.dismiss(key: ToastKey.translationUnavailable)
        }
    }

    private var retryAction: ToastCenter.Action {
        ToastCenter.Action(
            label: "Retry", handler: { [weak self] in self?.retryTranslation() }
        )
    }

    /// The one-way latch: once on Apple for the rest of the session (no
    /// periodic re-probing). Publishes `.degraded` so the footer explains the
    /// switch; the fresh Apple run publishes `.ready` over it once flowing.
    private func fallBackToApple(severity: TranslationFailureSeverity) {
        activeTranslationEngine = .apple
        translationStatus = .degraded("External translation failed — using Apple on-device", severity)
        reconcileTranslationToasts(translationStatus)
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
}
