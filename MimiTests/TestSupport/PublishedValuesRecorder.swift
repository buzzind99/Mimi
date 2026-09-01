import Combine
import Foundation

/// Reference box that records every value a Combine publisher emits after
/// the current one. Swift Testing suites are structs and `sink` closures
/// escape, so the subscription and the recorded values live in this class;
/// a suite keeps the recorder alive for the test's scope.
final class PublishedValuesRecorder<Value> {
    private(set) var values: [Value] = []
    private var subscription: AnyCancellable?

    init(_ publisher: some Publisher<Value, Never>) {
        subscription = publisher.dropFirst().sink { [weak self] value in
            self?.values.append(value)
        }
    }
}
