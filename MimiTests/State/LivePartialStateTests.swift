@testable import Mimi
import Testing

/// Tests `LivePartialState` observed partial set/clear.
@MainActor
@Suite("LivePartialState")
struct LivePartialStateTests {

    // MARK: - Helpers

    private func makeSUT() -> (LivePartialState, ObservedValuesRecorder<String>) {
        let sut = LivePartialState()
        let observed = ObservedValuesRecorder(read: { sut.partial })
        return (sut, observed)
    }

    // MARK: - Observed partial

    @Test("setting the partial fires the new value")
    func setFiresNewValue() async {
        let (sut, observed) = makeSUT()

        sut.partial = "こんにちは"

        #expect(sut.partial == "こんにちは")
        #expect(await pollUntil { observed.values == ["こんにちは"] }, "the recorder fires the new partial")
    }

    @Test("clearing the partial fires an empty string")
    func clearFiresEmptyString() async {
        let (sut, observed) = makeSUT()
        sut.partial = "こんにちは"
        #expect(await pollUntil { observed.values == ["こんにちは"] })

        sut.partial = ""
        #expect(await pollUntil { observed.values == ["こんにちは", ""] })

        #expect(sut.partial == "")
    }
}
