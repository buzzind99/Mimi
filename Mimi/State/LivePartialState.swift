import Foundation

/// High-frequency live subtitle state (partials arrive at 6–10 Hz). Observed
/// only by the live subtitle row and the HUD — partial updates never re-render
/// the transcript history.
@Observable
@MainActor
final class LivePartialState {
    /// Current in-flight partial (unstamped, still forming).
    var partial: String = ""
}
