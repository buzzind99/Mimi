@testable import Mimi
import Testing

/// Direct assertions for `AudioLevels.rms`, which otherwise only executes
/// indirectly inside the capture hot path: pins the empty-input branch, the
/// constant-amplitude identity, and the squaring that makes sign cancel.
@Suite("AudioLevels")
struct AudioLevelsTests {

    @Test("rms of empty input is zero")
    func emptyIsZero() {
        #expect(AudioLevels.rms(of: []) == 0)
    }

    @Test("rms of a constant buffer equals its amplitude")
    func constantEqualsAmplitude() {
        #expect(AudioLevels.rms(of: .init(repeating: 0.5, count: 100)) == 0.5)
    }

    @Test("rms squares before averaging, so sign cancels")
    func signCancels() {
        #expect(abs(AudioLevels.rms(of: [0.5, -0.5]) - 0.5) < 1e-6)
    }
}
