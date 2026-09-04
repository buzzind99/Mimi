@testable import Mimi
import Testing

/// Tests `LatencyState` rounding/observation behavior: values round to 0.1 s,
/// the 0.05 boundary rounds up, equal rounded values never re-fire, and
/// `reset()` is a no-op at zero.
@MainActor
@Suite("LatencyState")
struct LatencyStateTests {

    // MARK: - Helpers

    private func makeSUT() -> (LatencyState, ObservedValuesRecorder<Double>) {
        let sut = LatencyState()
        let observed = ObservedValuesRecorder(read: { sut.seconds })
        return (sut, observed)
    }

    // MARK: - update(_:)

    @Test("rounds a sub-tenth value to the tenth of a second")
    func subTenthValueRoundsToTenth() async {
        let (sut, observed) = makeSUT()

        sut.update(0.14)

        #expect(sut.seconds == 0.1)
        #expect(await pollUntil { observed.values == [0.1] }, "the recorder fires the rounded value")
    }

    @Test("rounds a value above the boundary up to the next tenth")
    func aboveBoundaryRoundsUp() {
        let (sut, _) = makeSUT()

        sut.update(0.16)

        #expect(sut.seconds == 0.2)
    }

    @Test("rounds the exact 0.05 boundary up")
    func exactBoundaryRoundsUp() {
        let (sut, _) = makeSUT()

        sut.update(0.05)

        #expect(sut.seconds == 0.1)
    }

    @Test("rounds a value just below the boundary down")
    func justBelowBoundaryRoundsDown() {
        let (sut, _) = makeSUT()

        sut.update(0.04)

        #expect(sut.seconds == 0.0)
    }

    @Test("does not re-fire when the rounded value is unchanged")
    func unchangedValueDoesNotRefire() async {
        let (sut, observed) = makeSUT()

        sut.update(0.3)
        #expect(await pollUntil { observed.values == [0.3] })
        sut.update(0.31)
        await flushObservations()

        #expect(observed.values == [0.3], "an unchanged rounded value must not re-fire")
        #expect(sut.seconds == 0.3)
    }

    // MARK: - reset()

    @Test("reset fires zero after a nonzero value")
    func resetFiresZero() async {
        let (sut, observed) = makeSUT()
        sut.update(0.42)
        #expect(await pollUntil { observed.values == [0.4] })

        sut.reset()
        #expect(await pollUntil { observed.values == [0.4, 0.0] })

        #expect(sut.seconds == 0.0)
    }

    @Test("reset is a no-op at zero and fires nothing")
    func resetAtZeroDoesNotFire() async {
        let (sut, observed) = makeSUT()

        sut.reset()
        await flushObservations()

        #expect(sut.seconds == 0.0)
        #expect(observed.values.isEmpty)
    }
}
