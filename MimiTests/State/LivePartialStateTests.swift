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

    /// Lets the recorder's post-mutation read hops run before assertions.
    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    // MARK: - Observed partial

    @Test("setting the partial fires the new value")
    func setFiresNewValue() async {
        let (sut, observed) = makeSUT()

        sut.partial = "こんにちは"
        await settle()

        #expect(sut.partial == "こんにちは")
        #expect(observed.values == ["こんにちは"])
    }

    @Test("clearing the partial fires an empty string")
    func clearFiresEmptyString() async {
        let (sut, observed) = makeSUT()
        sut.partial = "こんにちは"
        await settle()

        sut.partial = ""
        await settle()

        #expect(sut.partial == "")
        #expect(observed.values == ["こんにちは", ""])
    }
}
