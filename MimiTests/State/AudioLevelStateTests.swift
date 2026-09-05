import Foundation
@testable import Mimi
import Testing

/// Tests `AudioLevelState`: the fixed-size rolling ring (append + evict
/// oldest), the dBFS −60…0 → 0…1 mapping with both clamps, the dB readout
/// formatting ("−∞" for silence), and `reset()`.
@MainActor
@Suite("AudioLevelState")
struct AudioLevelStateTests {

    // MARK: - Ring

    @Test("update appends to the ring and evicts the oldest slot")
    func updateEvictsOldestSlot() {
        let sut = AudioLevelState()
        for _ in 0 ..< AudioLevelState.slotCount {
            sut.update(rms: 1.0)
        }

        sut.update(rms: 0)

        #expect(sut.levels.count == AudioLevelState.slotCount, "the ring stays fixed-size")
        #expect(sut.levels.last == 0, "the newest chunk sits at the end")
        #expect(sut.levels.first == 1.0, "the oldest slot was evicted, not grown past")
    }

    @Test("a fresh state flatlines at zero")
    func freshStateFlatlines() {
        let sut = AudioLevelState()

        #expect(sut.levels == Array(repeating: 0, count: AudioLevelState.slotCount))
        #expect(sut.currentDB == "−∞")
    }

    // MARK: - dB mapping

    @Test("chunk RMS maps into the ring and the dB readout", arguments: [
        (Float(1.0), 1.0, "0 dB"),
        (Float(0.0), 0.0, "−∞"),
        (Float(1e-4), 0.0, "−60 dB"),
        (Float(10.0), 1.0, "0 dB"),
    ])
    func rmsMapsToLevelAndReadout(rms: Float, level: Double, readout: String) {
        let sut = AudioLevelState()

        sut.update(rms: rms)

        #expect(sut.levels.last == level)
        #expect(sut.currentDB == readout)
    }

    /// −20 dBFS sits two-thirds up the meter (the (dB + 60) / 60 mapping);
    /// the readout rounds the dBFS value.
    @Test("a −20 dBFS chunk maps near two-thirds of the meter")
    func twentyBelowFullScaleMapsNearTwoThirds() throws {
        let sut = AudioLevelState()

        sut.update(rms: 0.1)

        let level = try #require(sut.levels.last)
        #expect(abs(level - 2.0 / 3.0) < 0.001)
        #expect(sut.currentDB == "−20 dB")
    }

    // MARK: - dBFS

    @Test("a full-scale chunk reads 0 dBFS")
    func fullScaleReadsZeroDBFS() {
        let sut = AudioLevelState()

        sut.update(rms: 1.0)

        #expect(sut.dBFS == 0)
    }

    @Test("a silent chunk reads −∞ dBFS")
    func silenceReadsNegativeInfinityDBFS() {
        let sut = AudioLevelState()

        sut.update(rms: 0)

        #expect(sut.dBFS == -.infinity)
    }

    // MARK: - reset

    @Test("reset clears the ring and the readout")
    func resetClearsRingAndReadout() {
        let sut = AudioLevelState()
        sut.update(rms: 0.5)

        sut.reset()

        #expect(sut.levels == Array(repeating: 0, count: AudioLevelState.slotCount))
        #expect(sut.dBFS == -.infinity)
        #expect(sut.currentDB == "−∞")
    }
}
