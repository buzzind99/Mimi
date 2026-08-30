import Combine
@testable import Mimi
import XCTest

/// Tests `LivePartialState` published partial set/clear.
@MainActor
final class LivePartialStateTests: XCTestCase {

    // MARK: - Fixtures

    private var publishedValues: [String] = []
    private var cancellable: AnyCancellable?

    // MARK: - Helpers

    private func makeSUT() -> LivePartialState {
        let sut = LivePartialState()
        cancellable = sut.$partial.dropFirst().sink { [weak self] value in
            self?.publishedValues.append(value)
        }
        return sut
    }

    // MARK: - Published partial

    func test_partial_whenSet_shouldPublishNewValue() {
        let sut = makeSUT()

        sut.partial = "こんにちは"

        XCTAssertEqual(sut.partial, "こんにちは")
        XCTAssertEqual(publishedValues, ["こんにちは"])
    }

    func test_partial_whenCleared_shouldPublishEmptyString() {
        let sut = makeSUT()
        sut.partial = "こんにちは"

        sut.partial = ""

        XCTAssertEqual(sut.partial, "")
        XCTAssertEqual(publishedValues, ["こんにちは", ""])
    }
}
