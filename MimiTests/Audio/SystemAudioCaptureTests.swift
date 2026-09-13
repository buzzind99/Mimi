import CoreGraphics
import Foundation
@testable import Mimi
import ScreenCaptureKit
import Testing

/// Tests `SystemAudioCapture`'s data path through the internal delegate
/// seams (`handleSampleBuffer`), driven by synthesized `CMSampleBuffer`s
/// from `SampleBufferSynthesis` — no ScreenCaptureKit involved, and the
/// callbacks run synchronously on the calling thread. `ensurePermission()`'s
/// preflight-granted arm is covered machine-gated (a Screen Recording grant
/// on the host). Excluded (needs TCC interaction and a live display stream):
/// `start()`'s SCK stream setup, `ensurePermission()`'s request arm, and
/// `stop()`'s SCK teardown — the stop fence and dead-stream reset live in
/// `SystemAudioCaptureTeardownTests`. The resample converter-failure branch
/// is not fixture-reachable either: Core Media rejects non-positive sample
/// rates before a converter is ever built, and any positive rate builds one.
@Suite("SystemAudioCapture")
struct SystemAudioCaptureTests {

    // MARK: - Fixtures

    private let recorder = DeliveryRecorder()

    /// Appends chunks/errors from the capture's callbacks. A reference box so
    /// the escaping callbacks can append; a fresh suite instance per test
    /// keeps tests isolated.
    private final class DeliveryRecorder: @unchecked Sendable {
        private(set) var chunks: [AudioChunk] = []
        private(set) var errors: [CaptureError] = []

        func record(_ chunk: AudioChunk) {
            chunks.append(chunk)
        }

        func record(_ error: CaptureError) {
            errors.append(error)
        }
    }

    // MARK: - Helpers

    private func makeCapture(running: Bool) -> SystemAudioCapture {
        let capture = SystemAudioCapture()
        let recorder = recorder
        capture.onChunk = { recorder.record($0) }
        capture.onIOError = { recorder.record($0) }
        if running {
            capture.setRunningForTesting(true)
        }
        return capture
    }

    // MARK: - Constants

    @Test("chunk constants target mono 16 kHz 160 ms chunks")
    func chunkConstants() {
        #expect(SystemAudioCapture.outputSampleRate == 16000)
        #expect(SystemAudioCapture.chunkSamples == 2560)
        #expect(SystemAudioCapture.captureSampleRate == 48000)
    }

    // MARK: - AudioChunk

    @Test("a chunk carries its samples and start offset")
    func chunkCarriesSamplesAndOffset() {
        let samples: [Float] = [0.1, -0.2, 0.3]

        let chunk = AudioChunk(samples: samples, startSample: 5120)

        #expect(chunk.samples == samples)
        #expect(chunk.startSample == 5120)
    }

    @Test("a chunk snapshots the samples it was given")
    func chunkSnapshotsSamples() {
        var samples: [Float] = [1, 2, 3]

        let chunk = AudioChunk(samples: samples, startSample: 0)
        samples.append(4)

        #expect(chunk.samples == [1, 2, 3])
    }

    // MARK: - Lifecycle guards (the SCK shell itself stays excluded)

    @Test("stop is a safe no-op while not running")
    func stopWhenNotRunning() {
        let capture = SystemAudioCapture()

        capture.stop()

        #expect(!capture.isRunning)
    }

    // MARK: - ensurePermission

    @Test(
        "ensurePermission returns true on the preflight-granted arm",
        .enabled(if: CGPreflightScreenCaptureAccess())
    )
    func ensurePermissionGrantedArm() async {
        #expect(await SystemAudioCapture.ensurePermission())
    }

    // MARK: - CaptureError descriptions

    @Test("permissionDenied explains the grant and restart steps")
    func permissionDeniedDescription() {
        #expect(
            CaptureError.permissionDenied.errorDescription
                == "Screen Recording access is required to capture system audio. Grant it "
                + "in System Settings → Privacy & Security → Screen Recording, then restart Mimi."
        )
    }

    @Test("noDisplayFound explains the missing display")
    func noDisplayFoundDescription() {
        #expect(
            CaptureError.noDisplayFound.errorDescription
                == "No display available to attach the audio stream to."
        )
    }

    @Test("streamSetupFailed includes the detail")
    func streamSetupFailedDescription() {
        #expect(
            CaptureError.streamSetupFailed("stream stopped").errorDescription
                == "Failed to start system audio capture: stream stopped"
        )
    }

    @Test("formatUnavailable explains the unusable format")
    func formatUnavailableDescription() {
        #expect(
            CaptureError.formatUnavailable.errorDescription
                == "Could not process the captured audio format."
        )
    }

    // MARK: - Sample-callback guards

    @Test("a non-audio output type is ignored")
    func nonAudioOutputTypeIgnored() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 2560)

        capture.handleSampleBuffer(buffer, type: .screen)

        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.isEmpty)
    }

    @Test("a sample buffer while not running is ignored")
    func samplesIgnoredWhileNotRunning() throws {
        let capture = makeCapture(running: false)
        let buffer = try SampleBufferSynthesis.make(frames: 2560)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.isEmpty)
    }

    @Test("a sample buffer whose data is not ready is ignored")
    func notReadyBufferIgnored() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 2560, dataReady: false)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.isEmpty)
    }

    @Test("a sample buffer without a format description is ignored")
    func missingFormatDescriptionIgnored() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 2560, withFormatDescription: false)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.isEmpty)
    }

    @Test("a non-LinearPCM buffer is ignored")
    func nonPCMBufferIgnored() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 2560, format: .nonPCM)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.isEmpty)
    }

    @Test("a zero-frame buffer is ignored")
    func zeroFrameBufferIgnored() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 0)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.isEmpty)
    }

    // MARK: - extractMono downmix

    @Test("mono 16 kHz frames pass through as one exact 160 ms chunk")
    func monoPassthroughChunk() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 2560)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.chunks.count == 1)
        let chunk = try #require(recorder.chunks.first)
        #expect(chunk.samples == (0 ..< 2560).map(Float.init))
        #expect(chunk.startSample == 0)
    }

    @Test("interleaved stereo frames downmix to the channel average")
    func interleavedStereoDownmix() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 2560, channels: 2, interleaved: true)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.chunks.count == 1)
        let chunk = try #require(recorder.chunks.first)
        #expect(chunk.samples == (0 ..< 2560).map { Float($0) + 5000 })
        #expect(chunk.startSample == 0)
    }

    @Test("deinterleaved stereo frames downmix to the channel average")
    func deinterleavedStereoDownmix() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 2560, channels: 2, interleaved: false)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.chunks.count == 1)
        let chunk = try #require(recorder.chunks.first)
        #expect(chunk.samples == (0 ..< 2560).map { Float($0) + 5000 })
        #expect(chunk.startSample == 0)
    }

    // MARK: - emitFixedChunks

    @Test("a callback's samples slice into exact 160 ms chunks")
    func slicesExactChunksFromOneCallback() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 3 * 2560)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.chunks.count == 3)
        #expect(recorder.chunks.map(\.startSample) == [0, 2560, 5120])
        let third = try #require(recorder.chunks.last)
        #expect(third.samples == (5120 ..< 7680).map(Float.init))
    }

    @Test("a remainder below the chunk size is retained and leads the next chunk")
    func remainderRetainedAcrossCallbacks() throws {
        let capture = makeCapture(running: true)
        let first = try SampleBufferSynthesis.make(frames: 2561)
        let second = try SampleBufferSynthesis.make(frames: 2560)

        capture.handleSampleBuffer(first, type: .audio)
        let firstChunk = try #require(recorder.chunks.first)

        #expect(recorder.chunks.count == 1)
        #expect(firstChunk.samples.count == 2560)

        capture.handleSampleBuffer(second, type: .audio)

        #expect(recorder.chunks.count == 2)
        let secondChunk = try #require(recorder.chunks.last)
        #expect(secondChunk.startSample == 2560)
        #expect(secondChunk.samples == [2560] + (0 ..< 2559).map(Float.init))
    }

    // MARK: - Resample

    @Test("44.1 kHz mono input is resampled to 16 kHz before chunking")
    func resamplesToOutputRate() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 8192, sampleRate: 44100)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.errors.isEmpty)
        #expect(recorder.chunks.count == 1)
        let chunk = try #require(recorder.chunks.first)
        #expect(chunk.samples.count == 2560)
        #expect(chunk.startSample == 0)
        // The input ramp makes the conversion computable: output index k
        // tracks input position k * 44100/16000 on the ramp. A converter
        // emitting zeros or bounded garbage fails; the tolerance absorbs
        // interpolation and any small priming phase shift.
        for k in [0, 1, 1024, 2559] {
            let expected = Float(Double(k) * 44100 / 16000)
            #expect(
                abs(chunk.samples[k] - expected) < 2,
                "k=\(k): got \(chunk.samples[k]), expected ~\(expected)"
            )
        }
    }

    @Test("48 kHz input keeps delivering chunks across successive callbacks")
    func resamplesAcrossSuccessiveCallbacks() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 7680, sampleRate: 48000)

        for _ in 0 ..< 4 {
            capture.handleSampleBuffer(buffer, type: .audio)
        }

        // A converter that latches to end-of-stream after the first callback
        // yields exactly one chunk and then starves; a correctly streamed
        // converter keeps cutting chunks, each a full 160 ms.
        #expect(recorder.errors.isEmpty)
        #expect(recorder.chunks.count >= 3)
        #expect(
            recorder.chunks.map(\.startSample)
                == (0 ..< recorder.chunks.count).map { $0 * 2560 }
        )
        #expect(recorder.chunks.allSatisfy { $0.samples.count == 2560 })
    }

    @Test("a mid-stream sample-rate change rebuilds the converter and keeps chunks contiguous")
    func rateChangeRebuildsConverter() throws {
        let capture = makeCapture(running: true)

        try capture.handleSampleBuffer(
            SampleBufferSynthesis.make(frames: 8192, sampleRate: 44100), type: .audio
        )
        // The fresh 48 kHz converter's priming backlog withholds a few
        // hundred early output frames, so feed several callbacks before
        // counting chunks — same accepted looseness as
        // `resamplesAcrossSuccessiveCallbacks`.
        for _ in 0 ..< 4 {
            try capture.handleSampleBuffer(
                SampleBufferSynthesis.make(frames: 7680, sampleRate: 48000), type: .audio
            )
        }

        // The rate change must not reuse the 44.1 kHz converter: a stale
        // converter mis-converts or starves, breaking the chunk stream.
        #expect(recorder.errors.isEmpty)
        #expect(recorder.chunks.count >= 3)
        #expect(
            recorder.chunks.map(\.startSample)
                == (0 ..< recorder.chunks.count).map { $0 * 2560 }
        )
        #expect(recorder.chunks.allSatisfy { $0.samples.count == 2560 })
    }

    @Test("a resampled remainder below the chunk size is retained and leads the next chunk")
    func resampledRemainderRetained() throws {
        let capture = makeCapture(running: true)

        // 6144 frames at 48 kHz → ≤ 2048 ideal output frames, and the
        // converter's priming backlog only lowers that — safely below the
        // chunk size, so the accumulator holds a resampled remainder.
        try capture.handleSampleBuffer(
            SampleBufferSynthesis.make(frames: 6144, sampleRate: 48000), type: .audio
        )
        #expect(recorder.chunks.isEmpty)

        // Steady-state output is a full chunk's worth, topping up the
        // remainder to exactly one more chunk.
        try capture.handleSampleBuffer(
            SampleBufferSynthesis.make(frames: 7680, sampleRate: 48000), type: .audio
        )

        #expect(recorder.errors.isEmpty)
        #expect(recorder.chunks.count == 1)
        let chunk = try #require(recorder.chunks.first)
        #expect(chunk.startSample == 0)
        // The chunk's first frame tracks the input ramp near position 0 —
        // proof the remainder led it. A dropped remainder would start this
        // chunk near input position 6144 * 48000 / 16000 ≈ 18_432.
        #expect(chunk.samples[0] < 100)
    }

    @Test("a larger callback after a small one reallocates the converter buffers")
    func bufferGrowthAcrossCallbacks() throws {
        let capture = makeCapture(running: true)

        // 320 frames seed the input/output PCM buffers; the 60× larger
        // callback must grow both instead of clipping or failing.
        try capture.handleSampleBuffer(
            SampleBufferSynthesis.make(frames: 320, sampleRate: 48000), type: .audio
        )
        try capture.handleSampleBuffer(
            SampleBufferSynthesis.make(frames: 3 * 7680, sampleRate: 48000), type: .audio
        )

        #expect(recorder.errors.isEmpty)
        #expect(recorder.chunks.map(\.startSample) == [0, 2560, 5120])
        #expect(recorder.chunks.allSatisfy { $0.samples.count == 2560 })
    }

    @Test("a non-float32 PCM payload surfaces formatUnavailable")
    func int16PayloadSurfacesFormatUnavailable() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 2560, format: .int16)

        capture.handleSampleBuffer(buffer, type: .audio)

        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.count == 1)
        let error = try #require(recorder.errors.first)
        guard case .formatUnavailable = error else {
            Issue.record("expected .formatUnavailable, got \(error)")
            return
        }
    }
}
