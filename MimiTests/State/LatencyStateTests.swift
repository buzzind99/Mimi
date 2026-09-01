import Combine
@testable import Mimi
import Testing

/// Tests `LatencyState` rounding/publish behavior: values round to 0.1 s,
/// the 0.05 boundary rounds up, equal rounded values never republish, and
/// `reset()` is a no-op at zero.
@MainActor
@Suite("LatencyState")
struct LatencyStateTests {

    // MARK: - Helpers

    private func makeSUT() -> (LatencyState, PublishedValuesRecorder<Double>) {
        let sut = LatencyState()
        let published = PublishedValuesRecorder(sut.$seconds)
        return (sut, published)
    }

    // MARK: - update(_:)

    @Test("rounds a sub-tenth value to the tenth of a second")
    func subTenthValueRoundsToTenth() {
        let (sut, published) = makeSUT()

        sut.update(0.14)

        #expect(sut.seconds == 0.1)
        #expect(published.values == [0.1])
    }

    @Test("rounds a value above the boundary up to the next tenth")
    func aboveBoundaryRoundsUp() {
        let (sut, published) = makeSUT()

        sut.update(0.16)

        #expect(sut.seconds == 0.2)
    }

    @Test("rounds the exact 0.05 boundary up")
    func exactBoundaryRoundsUp() {
        let (sut, published) = makeSUT()

        sut.update(0.05)

        #expect(sut.seconds == 0.1)
    }

    @Test("rounds a value just below the boundary down")
    func justBelowBoundaryRoundsDown() {
        let (sut, published) = makeSUT()

        sut.update(0.04)

        #expect(sut.seconds == 0.0)
    }

    @Test("does not republish when the rounded value is unchanged")
    func unchangedValueDoesNotRepublish() {
        let (sut, published) = makeSUT()

        sut.update(0.3)
        sut.update(0.31)

        #expect(published.values == [0.3])
        #expect(sut.seconds == 0.3)
    }

    // MARK: - reset()

    @Test("reset publishes zero after a nonzero value")
    func resetPublishesZero() {
        let (sut, published) = makeSUT()
        sut.update(0.42)

        sut.reset()

        #expect(sut.seconds == 0.0)
        #expect(published.values == [0.4, 0.0])
    }

    @Test("reset is a no-op at zero and publishes nothing")
    func resetAtZeroDoesNotPublish() {
        let (sut, published) = makeSUT()

        sut.reset()

        #expect(sut.seconds == 0.0)
        #expect(published.values.isEmpty)
    }
}
