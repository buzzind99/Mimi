import Foundation
@testable import Mimi
import Testing

/// Tests `ASRModelSettings` persistence over isolated `UserDefaults` suites
/// (per `UNIT_TEST_NEW.md`): the production default, persisted round-trip,
/// and the stable raw-value contract the storage payload relies on.
@MainActor
@Suite("ASRModelSettings")
struct ASRModelSettingsTests {

    // MARK: - Defaults

    @Test("a fresh selection defaults to Lite")
    func defaultsToLite() {
        let settings = isolatedASRModelSettings(suite: "test.ASRModelSettings")

        #expect(settings.selected == .lite)
    }

    @Test("an unknown persisted raw value degrades to Lite")
    func unknownRawValueDegradesToLite() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.ASRModelSettings.\(UUID().uuidString)"))
        defaults.set("bogus", forKey: "asr.model")

        let settings = ASRModelSettings(defaults: defaults)

        #expect(settings.selected == .lite)
    }

    // MARK: - Persistence

    @Test("a selection persists across instances over the same suite")
    func selectionPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.ASRModelSettings.\(UUID().uuidString)"))

        let first = ASRModelSettings(defaults: defaults)
        first.select(.full)
        #expect(first.selected == .full)

        let second = ASRModelSettings(defaults: defaults)

        #expect(second.selected == .full)
    }

    @Test("a Lite selection overwrites a persisted Full selection")
    func liteSelectionOverwrites() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.ASRModelSettings.\(UUID().uuidString)"))

        let first = ASRModelSettings(defaults: defaults)
        first.select(.full)
        first.select(.lite)

        let second = ASRModelSettings(defaults: defaults)

        #expect(second.selected == .lite)
    }

    // MARK: - Storage contract

    /// The raw values are the UserDefaults payload; changing them silently
    /// resets users to the default.
    @Test("raw values are the stable storage payload")
    func rawValuesAreStable() {
        #expect(ASRModelChoice.lite.rawValue == "lite")
        #expect(ASRModelChoice.full.rawValue == "full")
    }

    @Test("the storage key is stable")
    func storageKeyIsStable() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.ASRModelSettings.\(UUID().uuidString)"))
        let settings = ASRModelSettings(defaults: defaults)
        settings.select(.full)

        #expect(defaults.string(forKey: "asr.model") == "full")
    }
}
