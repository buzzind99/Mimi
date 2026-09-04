import Foundation
import Observation

/// Records values read through an `@Observable` object's tracked properties.
/// Re-arms `withObservationTracking` after every observed change so a
/// sequence of mutations is captured, mirroring what a Combine
/// `$`-publisher sink recorded before the `@Observable` migration. The
/// tracked read happens at init; every recorded value is the post-mutation
/// read. The tracking handler fires before the mutation commits, so each
/// recorded read hops to the main actor first — tests must gate on the recorded value (`pollUntil`)
/// between a mutation and its assertion, and between successive mutations.
/// All models observed here are `@MainActor`.
@MainActor
final class ObservedValuesRecorder<Value: Equatable> {
    private(set) var values: [Value] = []
    private let read: () -> Value

    init(read: @escaping () -> Value) {
        self.read = read
        arm()
    }

    private func arm() {
        withObservationTracking {
            _ = read()
        } onChange: {
            Task { @MainActor in
                self.recordChange()
            }
        }
    }

    private func recordChange() {
        values.append(read())
        arm()
    }
}

/// Bounded main-actor drain for absence assertions: gives the recorder's
/// post-mutation read hops (and any other unstructured `Task { @MainActor }`
/// callbacks) a generous window to run before asserting that nothing fired.
/// Absence has no observable success state to gate on, so the window is
/// fixed by design — a sleep during which the main actor is free to serve
/// the hops, plus yield slots for anything already enqueued.
@MainActor
func flushObservations() async {
    try? await Task.sleep(for: .milliseconds(100))
    for _ in 0 ..< 20 {
        await Task.yield()
    }
}
