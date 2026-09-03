import Foundation

/// High-frequency latency estimate, updated per 160 ms audio chunk. Observed
/// only by the status bar — latency updates never re-render the transcript
/// history or the HUD.
@Observable
@MainActor
final class LatencyState {
    /// Seconds of audio pushed to the engine but not yet processed,
    /// rounded to 0.1 s so observation fires only on visible change.
    var seconds: Double = 0

    func update(_ raw: Double) {
        let rounded = (raw * 10).rounded() / 10
        if rounded != seconds {
            seconds = rounded
        }
    }

    func reset() {
        if seconds != 0 {
            seconds = 0
        }
    }
}
