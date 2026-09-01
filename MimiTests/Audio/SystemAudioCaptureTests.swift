import Foundation
@testable import Mimi
import ScreenCaptureKit
import Testing

/// Tests `SystemAudioCapture`'s data path through the internal delegate
/// seams (`handleSampleBuffer`/`handleStreamStopped`), driven by synthesized
/// `CMSampleBuffer`s from `SampleBufferSynthesis` — no ScreenCaptureKit
/// involved, and the stop fence is deterministic because the callbacks run
/// synchronously on the calling thread. Excluded (needs a Screen Recording
/// grant and a live display stream): `start()`, `ensurePermission()`, and
/// `stop()`'s SCK teardown. The resample converter-failure branch is not
/// fixture-reachable either: Core Media rejects non-positive sample rates
/// before a converter is ever built, and any positive rate builds one.
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
        let recorder = self.recorder
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
        #expect(Double(SystemAudioCapture.chunkSamples) == SystemAudioCapture.outputSampleRate * 0.16)
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

    // MARK: - Resample fallback

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
        #expect(chunk.samples.allSatisfy { $0 >= -1 && $0 <= 8192 })
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

    // MARK: - Stop fence

    @Test("stop() fences an in-flight callback and nothing lands after it returns")
    func stopFencesInFlightCallback() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 2 * 2560)
        let recorder = self.recorder

        // Hold the first chunk delivery inside the callback (under the
        // capture's state lock): stop() must not be able to return until the
        // in-flight callback finishes, and no chunk may land afterwards.
        let chunkDelivered = DispatchSemaphore(value: 0)
        let deliveryGate = NSLock()
        deliveryGate.lock()
        capture.onChunk = { chunk in
            recorder.record(chunk)
            chunkDelivered.signal()
            deliveryGate.lock()
            deliveryGate.unlock()
        }

        let callbackThread = Thread {
            capture.handleSampleBuffer(buffer, type: .audio)
        }
        callbackThread.start()
        #expect(chunkDelivered.wait(timeout: .now() + 2) == .success)
        #expect(recorder.chunks.count == 1)

        let stopReturned = DispatchSemaphore(value: 0)
        let stopThread = Thread {
            capture.stop()
            stopReturned.signal()
        }
        stopThread.start()
        #expect(stopReturned.wait(timeout: .now() + 0.2) == .timedOut)

        deliveryGate.unlock()
        #expect(stopReturned.wait(timeout: .now() + 2) == .success)
        #expect(!capture.isRunning)
        #expect(recorder.chunks.count == 2)
        #expect(recorder.chunks.map(\.startSample) == [0, 2560])
        #expect(recorder.errors.isEmpty)
    }

    @Test("sample buffers are dropped after stop() returns")
    func samplesDroppedAfterStop() throws {
        let capture = makeCapture(running: true)
        let buffer = try SampleBufferSynthesis.make(frames: 2560)

        capture.handleSampleBuffer(buffer, type: .audio)
        #expect(recorder.chunks.count == 1)

        capture.stop()
        capture.handleSampleBuffer(buffer, type: .audio)
        #expect(!capture.isRunning)
        #expect(recorder.chunks.count == 1)
        #expect(recorder.errors.isEmpty)
    }

    @Test("a stop during extraction drops the in-flight samples")
    func stopDuringExtractionDropsSamples() throws {
        let capture = makeCapture(running: true)
        // A payload whose downmix is still running when stop() fires below:
        // the callback passes the cheap entry check, then gets fenced by the
        // locked re-check and must deliver nothing.
        let buffer = try SampleBufferSynthesis.make(frames: 16_000_000)

        let callbackFinished = DispatchSemaphore(value: 0)
        let callbackThread = Thread {
            capture.handleSampleBuffer(buffer, type: .audio)
            callbackFinished.signal()
        }
        callbackThread.start()
        Thread.sleep(forTimeInterval: 0.05)
        capture.stop()

        #expect(callbackFinished.wait(timeout: .now() + 10) == .success)
        #expect(!capture.isRunning)
        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.isEmpty)
    }

    // MARK: - SCStreamDelegate stop handling

    @Test("didStopWithError while running resets the state and reports the error")
    func streamStoppedWhileRunning() throws {
        let capture = makeCapture(running: true)
        let streamError = NSError(
            domain: "dev.mimi.tests", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "stream died"]
        )

        capture.handleStreamStopped(streamError)

        #expect(!capture.isRunning)
        #expect(recorder.chunks.isEmpty)
        #expect(recorder.errors.count == 1)
        let error = try #require(recorder.errors.first)
        guard case let .streamSetupFailed(detail) = error else {
            Issue.record("expected .streamSetupFailed, got \(error)")
            return
        }
        #expect(detail == "stream died")
    }

    @Test("didStopWithError while not running is a no-op")
    func streamStoppedWhenNotRunning() {
        let capture = makeCapture(running: false)
        let streamError = NSError(domain: "dev.mimi.tests", code: 7)

        capture.handleStreamStopped(streamError)

        #expect(!capture.isRunning)
        #expect(recorder.errors.isEmpty)
    }
}
