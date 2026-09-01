import Combine
@testable import Mimi
import Testing

/// Tests `LivePartialState` published partial set/clear.
@MainActor
@Suite("LivePartialState")
struct LivePartialStateTests {

    // MARK: - Helpers

    private func makeSUT() -> (LivePartialState, PublishedValuesRecorder<String>) {
        let sut = LivePartialState()
        let published = PublishedValuesRecorder(sut.$partial)
        return (sut, published)
    }

    // MARK: - Published partial

    @Test("setting the partial publishes the new value")
    func setPublishesNewValue() {
        let (sut, published) = makeSUT()

        sut.partial = "こんにちは"

        #expect(sut.partial == "こんにちは")
        #expect(published.values == ["こんにちは"])
    }

    @Test("clearing the partial publishes an empty string")
    func clearPublishesEmptyString() {
        let (sut, published) = makeSUT()
        sut.partial = "こんにちは"

        sut.partial = ""

        #expect(sut.partial == "")
        #expect(published.values == ["こんにちは", ""])
    }
}
