import Foundation

/// Audio level for the sidebar AUDIO card: a fixed 48-slot rolling ring of
/// normalized levels (dBFS −60…0 mapped to 0…1). `SessionController` stages
/// each 160 ms chunk's RMS off-main and feeds it here on the 60 ms poll tick
/// (alongside `latency`). Observed only by the meter view — level updates
/// never re-render the transcript history or the HUD.
@Observable
@MainActor
final class AudioLevelState {
    /// Ring capacity; matches the mock meter's bar count.
    static let slotCount = 48
    /// Full-scale floor: RMS at or below this level maps to 0.
    static let floorDB: Double = -60

    /// Rolling ring, oldest first (index 0) … newest last. Normalized 0…1.
    private(set) var levels: [Double] = Array(repeating: 0, count: AudioLevelState.slotCount)

    /// Latest chunk RMS in dBFS (−∞ before the first chunk and for true
    /// silence, i.e. zero-amplitude chunks).
    private(set) var dBFS: Double = -.infinity

    /// Maps one chunk's RMS into the ring. dBFS −60…0 → 0…1, clamped at
    /// both ends so out-of-range energy never overflows a bar.
    func update(rms: Float) {
        let db = rms > 0 ? 20 * log10(Double(rms)) : -.infinity
        dBFS = db
        let normalized = min(max((db - Self.floorDB) / -Self.floorDB, 0), 1)
        levels.removeFirst()
        levels.append(normalized)
    }

    /// Clears the ring (session begin/stop): the meter flatlines until the
    /// next chunk arrives.
    func reset() {
        levels = Array(repeating: 0, count: Self.slotCount)
        dBFS = -.infinity
    }

    /// AUDIO-card readout: "−6 dB" for finite levels (clamped to the
    /// −60…0 window), "−∞" when silent.
    var currentDB: String {
        guard dBFS.isFinite else { return "−∞" }
        let rounded = min(max(dBFS, Self.floorDB), 0).rounded()
        return rounded < 0 ? "−\(Int(-rounded)) dB" : "\(Int(rounded)) dB"
    }
}
