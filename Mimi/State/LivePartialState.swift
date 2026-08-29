import Foundation
import Combine

/// High-frequency live subtitle state (partials arrive at 6–10 Hz). Observed
/// only by the live subtitle row and the HUD — partial updates never re-render
/// the transcript history.
@MainActor
final class LivePartialState: ObservableObject {
    /// Current in-flight partial (unstamped, still forming).
    @Published var partial: String = ""
    /// Most recent finalized JP sentence (drives the HUD top line).
    @Published var lastFinalJP: Sentence?
    /// Most recent EN translation (drives the HUD second line).
    @Published var lastFinalEN: String = ""
}
