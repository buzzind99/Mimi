import Foundation
@testable import Mimi
import Testing

/// Tests `UIScale` stepping/clamping and the stable storage contract the
/// header stepper relies on.
@Suite("UIScale")
struct UIScaleTests {

    // MARK: - Decoding

    @Test("an unknown persisted raw value is not representable")
    func unknownRawValueIsUnrepresentable() {
        #expect(UIScale(rawValue: 50) == nil)
        #expect(UIScale(rawValue: 60) == nil)
        #expect(UIScale(rawValue: 225) == nil)
    }

    @Test("invalid stored values fall back to 100%")
    func invalidStoredValueFallsBackToDefault() {
        #expect(UIScale.default == .percent100)
    }

    // MARK: - Stepping

    @Test("stepping advances in 25% increments")
    func steppingAdvances() {
        #expect(UIScale.percent100.step(1) == .percent125)
        #expect(UIScale.percent125.step(-1) == .percent100)
        #expect(UIScale.percent175.step(1) == .percent200)
    }

    @Test("stepping clamps at both bounds")
    func steppingClamps() {
        #expect(UIScale.percent75.step(-1) == .percent75)
        #expect(UIScale.percent75.step(-5) == .percent75)
        #expect(UIScale.percent200.step(1) == .percent200)
        #expect(UIScale.percent200.step(5) == .percent200)
    }

    // MARK: - Storage contract

    /// The raw values are the UserDefaults payload; changing them silently
    /// resets users to the default.
    @Test("raw values are 25%-step percentages")
    func rawValuesArePercentages() {
        #expect(UIScale.allCases.map(\.rawValue) == [75, 100, 125, 150, 175, 200])
    }

    @Test("factors derive from raw values")
    func factorsDeriveFromRawValues() {
        #expect(UIScale.percent75.factor == 0.75)
        #expect(UIScale.percent100.factor == 1.0)
        #expect(UIScale.percent200.factor == 2.0)
    }

    @Test("labels render as percentages")
    func labelsRenderAsPercentages() {
        #expect(UIScale.percent75.label == "75%")
        #expect(UIScale.percent100.label == "100%")
        #expect(UIScale.percent200.label == "200%")
    }

    @Test("the storage key is stable")
    func storageKeyIsStable() {
        #expect(UIScale.storageKey == "UIScale")
    }
}
