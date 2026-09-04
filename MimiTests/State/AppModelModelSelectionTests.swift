import Foundation
@testable import Mimi
import Testing

/// Tests `AppModel`'s ASR model selection: the Lite default, per-choice
/// availability caching, and the `selectModel` gating (only a downloaded +
/// verified model, never mid-session) with re-resolve + auto-select on a
/// Settings download. The launch check itself is stubbed
/// (`initialModelResolve`): the real locator SHA-256-hashes up to ~1.2 GB —
/// real blocking work tests must never trigger.
@MainActor
@Suite("AppModel model selection")
struct AppModelModelSelectionTests {

    // MARK: - Helpers

    private func makeSUT(
        resolve: @escaping @Sendable (ASRModelChoice) -> URL? = { _ in nil }
    ) async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelSelection"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelSelection"),
            initialModelResolve: resolve
        )
        await model.initialModelCheck?.value
        return model
    }

    // MARK: - Defaults / availability

    @Test("ASR model selection defaults to Lite")
    func asrModelDefaultsToLite() async {
        let model = await makeSUT()

        #expect(model.asrModelSettings.selected == .lite)
    }

    @Test("model discovery caches availability for both choices")
    func refreshCachesAvailabilityPerChoice() async {
        let model = await makeSUT()
        let liteURL = URL(fileURLWithPath: "/tmp/lite.gguf")
        let fullURL = URL(fileURLWithPath: "/tmp/full.gguf")

        await model.refreshModelAvailability(resolve: { $0 == .full ? fullURL : liteURL })

        #expect(model.modelAvailability == [.lite: liteURL, .full: fullURL])
        #expect(model.modelURL == liteURL, "the active choice's URL becomes modelURL")
    }

    // MARK: - selectModel

    @Test("selectModel persists the choice and re-resolves into modelURL")
    func selectModelPersistsAndReresolves() async {
        let liteURL = URL(fileURLWithPath: "/tmp/lite.gguf")
        let fullURL = URL(fileURLWithPath: "/tmp/full.gguf")
        let model = await makeSUT(resolve: { choice in choice == .full ? fullURL : liteURL })
        model.phase = .idle

        model.selectModel(.full)
        await pollUntil { model.asrModelSettings.selected == .full && model.modelURL == fullURL }

        #expect(model.asrModelSettings.selected == .full)
        #expect(model.modelURL == fullURL)
        #expect(model.phase == .idle)
    }

    @Test("selectModel refuses a model that has not resolved")
    func selectModelRequiresAvailability() async {
        let model = await makeSUT()
        let liteURL = URL(fileURLWithPath: "/tmp/lite.gguf")
        await model.refreshModelAvailability(resolve: { choice in choice == .lite ? liteURL : nil })
        model.phase = .idle

        model.selectModel(.full)

        #expect(model.asrModelSettings.selected == .lite, "an unverified model cannot be selected")
    }

    @Test("selectModel is disabled while a session is running or starting")
    func selectModelDisabledMidSession() async {
        let model = await makeSUT()
        let fullURL = URL(fileURLWithPath: "/tmp/full.gguf")
        await model.refreshModelAvailability(resolve: { _ in fullURL })

        for phase in [SessionPhase.running, .starting] {
            model.phase = phase

            model.selectModel(.full)

            #expect(model.asrModelSettings.selected == .lite, "selection must be gated on \(phase)")
        }
        #expect(model.modelURL == fullURL, "the mid-session refusal must not disturb the active model")
    }

    // MARK: - Settings download completion

    @Test("adoptDownloadedModel refreshes availability and auto-selects the new model")
    func adoptDownloadedModelSelects() async {
        let fullURL = URL(fileURLWithPath: "/tmp/full.gguf")
        let model = await makeSUT(resolve: { choice in choice == .full ? fullURL : nil })
        model.phase = .idle

        await model.adoptDownloadedModel(.full)

        #expect(model.asrModelSettings.selected == .full)
        #expect(model.modelURL == fullURL)
        #expect(model.modelAvailability[.full] == fullURL)
    }
}
