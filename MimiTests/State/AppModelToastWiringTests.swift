import Foundation
@testable import Mimi
import Testing

/// Tests `AppModel`'s toast wiring for the translation-status rows of the
/// toast table, driven through `handleTranslationStatus`: post on entry,
/// dismiss on exit (`.ready` clears both cards when the fallback latch is
/// off; while latched it keeps the degraded card, `.translating` clears only
/// the unavailable one). The session-state cards (`capture.lost`,
/// `session.failed`, `asr.warning`, stop clearing) live in `AppModelTests`
/// and `AppModelSessionTests`.
@MainActor
@Suite("AppModel translation toast wiring")
struct AppModelToastWiringTests {

    // MARK: - Fixtures

    /// Stubbed launch check — see `AppModelTests.makeSUT`.
    private func makeSUT() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelToastWiring"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelToastWiring"),
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    // MARK: - Post on entry

    @Test("a retrying status posts the transient translation.retry card")
    func retryingStatusPostsTransientCard() async {
        let model = await makeSUT()

        model.handleTranslationStatus(.retrying("External translation failed, 2 retries left"))

        let toast = model.toasts.toasts.first { $0.key == ToastKey.translationRetry }
        #expect(toast?.style == .yellowAuto)
        #expect(toast?.body == "External translation failed, 2 retries left")
        #expect(toast?.action == nil)
    }

    @Test("a degraded status posts the persistent fallback card with Retry")
    func degradedStatusPostsFallbackCard() async {
        let model = await makeSUT()
        model.translationFallbackActive = true

        model.handleTranslationStatus(
            .degraded("External translation failed — using Apple on-device", .permanent)
        )

        let toast = model.toasts.toasts.first { $0.key == ToastKey.translationFallback }
        #expect(toast?.style == .yellowPersistent)
        #expect(toast?.action?.label == "Retry")
        #expect(!model.toasts.toasts.contains { $0.key == ToastKey.translationUnavailable })
    }

    @Test("an unavailable status posts the red card with Retry")
    func unavailableStatusPostsRedCard() async {
        let model = await makeSUT()
        model.translationFallbackActive = true

        model.handleTranslationStatus(
            .unavailable("Invalid API key. Check the key in Settings, then retry.", .permanent)
        )

        let toast = model.toasts.toasts.first { $0.key == ToastKey.translationUnavailable }
        #expect(toast?.style == .redPersistent)
        #expect(toast?.action?.label == "Retry")
        #expect(!model.toasts.toasts.contains { $0.key == ToastKey.translationFallback })
    }

    // MARK: - Dismiss on exit

    @Test("a ready status clears the degraded and unavailable cards when not latched")
    func readyStatusClearsBothCardsWhenNotLatched() async {
        let model = await makeSUT()
        model.handleTranslationStatus(
            .degraded("External translation failed — using Apple on-device", .permanent)
        )
        model.handleTranslationStatus(
            .unavailable("Network error reaching the provider. Check the connection, then retry.", .transient)
        )

        model.handleTranslationStatus(.ready)

        #expect(model.toasts.toasts.isEmpty)
    }

    /// The exact auto-fallback race: the fresh Apple run publishes `.ready`
    /// immediately at run start, but while the fallback latch is active the
    /// degraded card must survive — otherwise the Retry action flashes for
    /// under a second and never shows.
    @Test("a ready status keeps the fallback card while latched")
    func readyStatusKeepsFallbackCardWhileLatched() async {
        let model = await makeSUT()
        model.translationFallbackActive = true
        model.handleTranslationStatus(
            .degraded("External translation failed — using Apple on-device", .permanent)
        )

        model.handleTranslationStatus(.ready)

        let toast = model.toasts.toasts.first { $0.key == ToastKey.translationFallback }
        #expect(toast?.style == .yellowPersistent)
        #expect(toast?.action?.label == "Retry")
        #expect(!model.toasts.toasts.contains { $0.key == ToastKey.translationUnavailable })
    }

    /// The fallback card survives a mid-session status move: posting
    /// `.unavailable` dismisses it, but `.translating` (work resuming) must
    /// not.
    @Test("a translating status clears the unavailable card but keeps the fallback")
    func translatingStatusClearsUnavailableOnly() async {
        let model = await makeSUT()
        model.translationFallbackActive = true
        model.handleTranslationStatus(
            .degraded("External translation failed — using Apple on-device", .permanent)
        )

        model.handleTranslationStatus(.translating)

        #expect(!model.toasts.toasts.contains { $0.key == ToastKey.translationUnavailable })
        #expect(model.toasts.toasts.contains { $0.key == ToastKey.translationFallback })
    }
}
