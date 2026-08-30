import Combine
@testable import Mimi
import XCTest

/// Tests `LatencyState` rounding/publish behavior: values round to 0.1 s,
/// the 0.05 boundary rounds up, equal rounded values never republish, and
/// `reset()` is a no-op at zero.
@MainActor
final class LatencyStateTests: XCTestCase {

    // MARK: - Fixtures

    private var publishedValues: [Double] = []
    private var cancellable: AnyCancellable?

    // MARK: - Helpers

    private func makeSUT() -> LatencyState {
        let sut = LatencyState()
        cancellable = sut.$seconds.dropFirst().sink { [weak self] value in
            self?.publishedValues.append(value)
        }
        return sut
    }

    // MARK: - update(_:)

    func test_update_whenSubTenthValue_shouldRoundToTenthOfASecond() {
        let sut = makeSUT()

        sut.update(0.14)

        XCTAssertEqual(sut.seconds, 0.1)
    }

    func test_update_whenAboveRoundingBoundary_shouldRoundToNextTenth() {
        let sut = makeSUT()

        sut.update(0.16)

        XCTAssertEqual(sut.seconds, 0.2)
    }

    func test_update_whenExactlyAtBoundary_shouldRoundUp() {
        let sut = makeSUT()

        sut.update(0.05)

        XCTAssertEqual(sut.seconds, 0.1)
    }

    func test_update_whenJustBelowBoundary_shouldRoundDown() {
        let sut = makeSUT()

        sut.update(0.04)

        XCTAssertEqual(sut.seconds, 0.0)
    }

    func test_update_whenRoundedValueUnchanged_shouldNotPublish() {
        let sut = makeSUT()

        sut.update(0.3)
        sut.update(0.31)

        XCTAssertEqual(publishedValues, [0.3])
        XCTAssertEqual(sut.seconds, 0.3)
    }

    // MARK: - reset()

    func test_reset_whenNonZero_shouldPublishZero() {
        let sut = makeSUT()
        sut.update(0.42)

        sut.reset()

        XCTAssertEqual(sut.seconds, 0.0)
        XCTAssertEqual(publishedValues, [0.4, 0.0])
    }

    func test_reset_whenAlreadyZero_shouldNotPublish() {
        let sut = makeSUT()

        sut.reset()

        XCTAssertEqual(sut.seconds, 0.0)
        XCTAssertTrue(publishedValues.isEmpty)
    }
}
