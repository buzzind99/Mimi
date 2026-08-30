@testable import Mimi
import XCTest

/// Tests `SystemAudioCapture`'s reachable pure logic: the chunk-size
/// constants, `AudioChunk` value semantics, and the `CaptureError`
/// descriptions. The SCK shell (permission preflight, stream setup, delegate
/// plumbing) needs a Screen Recording grant and a live display stream
final class SystemAudioCaptureTests: XCTestCase {

    // MARK: - Constants

    func test_constants_shouldTargetMono16kHz160msChunks() {
        XCTAssertEqual(SystemAudioCapture.outputSampleRate, 16000)
        XCTAssertEqual(SystemAudioCapture.chunkSamples, 2560)
        XCTAssertEqual(Double(SystemAudioCapture.chunkSamples), SystemAudioCapture.outputSampleRate * 0.16)
    }

    // MARK: - AudioChunk

    func test_audioChunk_shouldCarrySamplesAndStartOffset() {
        let samples: [Float] = [0.1, -0.2, 0.3]
        let chunk = AudioChunk(samples: samples, startSample: 5120)

        XCTAssertEqual(chunk.samples, samples)
        XCTAssertEqual(chunk.startSample, 5120)
    }

    func test_audioChunk_shouldBeAValueType_safeAcrossQueues() {
        var samples: [Float] = [1, 2, 3]
        let chunk = AudioChunk(samples: samples, startSample: 0)
        samples.append(4) // mutating the source after construction

        XCTAssertEqual(chunk.samples, [1, 2, 3], "chunk snapshots the samples it was given")
    }

    // MARK: - Lifecycle guards (the SCK shell itself stays excluded)

    func test_stop_whenNotRunning_shouldBeSafeNoOp() {
        let capture = SystemAudioCapture()

        capture.stop()

        XCTAssertFalse(capture.isRunning, "no-op stop must not pretend a stream is up")
    }

    // MARK: - CaptureError descriptions

    func test_errorDescription_whenPermissionDenied_shouldExplainGrantAndRestart() {
        XCTAssertEqual(
            CaptureError.permissionDenied.errorDescription,
            "Screen Recording access is required to capture system audio. Grant it "
                + "in System Settings → Privacy & Security → Screen Recording, then restart Mimi."
        )
    }

    func test_errorDescription_whenNoDisplayFound() {
        XCTAssertEqual(
            CaptureError.noDisplayFound.errorDescription,
            "No display available to attach the audio stream to."
        )
    }

    func test_errorDescription_whenStreamSetupFailed_shouldIncludeDetail() {
        XCTAssertEqual(
            CaptureError.streamSetupFailed("stream stopped").errorDescription,
            "Failed to start system audio capture: stream stopped"
        )
    }

    func test_errorDescription_whenFormatUnavailable() {
        XCTAssertEqual(
            CaptureError.formatUnavailable.errorDescription,
            "Could not process the captured audio format."
        )
    }
}
