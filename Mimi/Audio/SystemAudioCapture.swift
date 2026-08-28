import AVFoundation
import Foundation
import ScreenCaptureKit

/// Emitted mono 16 kHz chunk (160 ms = 2,560 samples). `samples` is a value
/// type; safe to hand across queues.
struct AudioChunk: Sendable {
    let samples: [Float]
    /// Session-relative sample offset of the first sample.
    let startSample: Int
    /// True when the RMS gate classified the chunk as below-speech silence.
    let silent: Bool
}

/// Errors surfaced by the capture pipeline.
enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplayFound
    case streamSetupFailed(String)
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return
                "Screen Recording access is required to capture system audio. Grant it in System Settings → Privacy & Security → Screen Recording, then restart Mimi."
        case .noDisplayFound:
            return "No display available to attach the audio stream to."
        case .streamSetupFailed(let detail):
            return "Failed to start system audio capture: \(detail)"
        case .formatUnavailable:
            return "Could not process the captured audio format."
        }
    }
}

/// Captures the entirety of system audio with a ScreenCaptureKit audio-only
/// stream and delivers mono 16 kHz chunks.
///
/// Threading: sample buffers arrive on the dedicated SCK output queue; the
/// delegate downmixes/resamples when needed, slices 160 ms chunks, applies
/// the RMS gate, and calls `onChunk` on that queue.
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    static let outputSampleRate: Double = 16_000
    static let chunkSamples = Int(outputSampleRate * 0.16)

    var onChunk: ((AudioChunk) -> Void)?
    var onIOError: ((CaptureError) -> Void)?

    /// RMS gate thresholds (float32 linear). Speech enter/exit hysteresis.
    var gateOnThreshold: Float = 1.2e-3
    var gateOffThreshold: Float = 0.6e-3
    var gateHoldSeconds: Double = 0.5

    private let outputQueue = DispatchQueue(
        label: "dev.mimi.capture.sck", qos: .userInteractive)

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var cachedConverterRate: Double = 0
    private var accumulated: [Float] = []
    private var emittedSamples = 0
    private var gateSpeechActive = false
    private var gateLastSpeechAt: Date = .distantPast
    private var consecutiveSilentChunks = 0

    private(set) var isRunning = false

    /// True while the stream has delivered only gate-silenced audio for a
    /// stretch (debug aid for a dead pipeline).
    private(set) var isStreamSilent = false

    // MARK: - Permission

    /// Triggers the TCC prompt when undetermined. Returns false if Screen
    /// Recording has not been granted (granting requires an app restart).
    static func ensurePermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // The shareable-content query triggers the system prompt.
        _ = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        return CGPreflightScreenCaptureAccess()
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isRunning else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.streamSetupFailed(error.localizedDescription)
        }
        guard let display = content.displays.first else {
            throw CaptureError.noDisplayFound
        }

        // Whole-system audio: one display-scoped filter with Mimi's own app
        // removed; the stream config excludes this process's audio as well.
        let apps = content.applications.filter {
            $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: apps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.outputSampleRate)
        config.channelCount = 1
        // Audio-only stream: keep the (unused) video track as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
        } catch {
            self.stream = nil
            throw CaptureError.streamSetupFailed(error.localizedDescription)
        }

        isRunning = true
        #if DEBUG
        print("[capture] SCK system-audio stream started (target: 16 kHz mono)")
        #endif
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        let stream = self.stream
        self.stream = nil
        accumulated.removeAll(keepingCapacity: true)
        Task {
            try? await stream?.stopCapture()
            try? stream?.removeStreamOutput(self, type: .audio)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard isRunning else { return }
        isRunning = false
        self.stream = nil
        onIOError?(.streamSetupFailed(error.localizedDescription))
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, isRunning, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return }
        let deliveredFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard deliveredFrames > 0 else { return }

        guard let mono = extractMono(sampleBuffer: sampleBuffer, asbd: asbd) else {
            onIOError?(.formatUnavailable)
            return
        }
        guard !mono.isEmpty else { return }

        if asbd.mSampleRate == Self.outputSampleRate {
            accumulated.append(contentsOf: mono)
        } else {
            guard let converted = resample(mono, from: asbd.mSampleRate) else {
                onIOError?(.formatUnavailable)
                return
            }
            accumulated.append(contentsOf: converted)
        }
        emitFixedChunks()
    }

    // MARK: - PCM extraction

    /// Pulls float32 PCM out of the sample buffer and downmixes to mono.
    /// Handles both interleaved (one buffer, N channels) and deinterleaved
    /// (N one-channel buffers) layouts.
    private func extractMono(sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> [Float]? {
        guard MemoryLayout<Float>.size == 4, asbd.mBitsPerChannel == 32,
            asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else {
            print("unsupported SCK audio format: \(asbd)")
            return nil
        }

        // Two-pass: query the exact required size first (it includes the PCM
        // payload, not just the list struct), then fill the list.
        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil)
        guard status == noErr, listSize > 0 else {
            print("CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer (size): \(status)")
            return nil
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        memset(abl, 0, listSize)

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: abl, bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else {
            print("CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer: \(status)")
            return nil
        }
        // The payload lives in the retained block buffer; keep it alive while
        // the buffer list pointers are read below.
        guard let blockBuffer, blockBuffer.dataLength > 0 else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let nBuffers = Int(abl.pointee.mNumberBuffers)
        guard nBuffers >= 1, let firstData = buffers[0].mData else { return nil }

        var frames = 0
        var channels = 0
        var interleaved = false
        if nBuffers == 1 {
            channels = max(1, Int(buffers[0].mNumberChannels))
            interleaved = channels > 1
            frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size / channels
        } else {
            channels = nBuffers
            interleaved = false
            frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        }
        guard frames > 0, channels > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frames)
        let scale = 1.0 / Float(channels)
        for f in 0..<frames {
            var sum: Float = 0
            for ch in 0..<channels {
                let ptr: UnsafeMutablePointer<Float>
                if interleaved {
                    ptr = firstData.assumingMemoryBound(to: Float.self)
                    sum += ptr[f * channels + ch]
                } else {
                    guard let data = buffers[ch].mData else { continue }
                    ptr = data.assumingMemoryBound(to: Float.self)
                    sum += ptr[f]
                }
            }
            mono[f] = channels > 1 ? sum * scale : sum
        }
        return mono
    }

    // MARK: - Resample (fallback when SCK ignores the 16 kHz request)

    private lazy var outputFormat: AVAudioFormat = AVAudioFormat(
        standardFormatWithSampleRate: Self.outputSampleRate, channels: 1)!

    private func resample(_ mono: [Float], from rate: Double) -> [Float]? {
        guard let inFormat = AVAudioFormat(
            standardFormatWithSampleRate: rate, channels: 1)
        else { return nil }

        if cachedConverterRate != rate {
            guard let new = AVAudioConverter(from: inFormat, to: outputFormat) else {
                print("AVAudioConverter creation failed: \(inFormat) → \(outputFormat)")
                return nil
            }
            converter = new
            cachedConverterRate = rate
        }
        guard let converter else { return nil }

        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(mono.count))
        else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(mono.count)
        if let dst = inBuffer.floatChannelData?[0] {
            for (i, s) in mono.enumerated() { dst[i] = s }
        }

        let ratio = Self.outputSampleRate / rate
        let outCapacity = AVAudioFrameCount(Double(mono.count) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: outCapacity)
        else { return nil }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            fed = true
            return inBuffer
        }
        guard status != .error, conversionError == nil,
            let src = outBuffer.floatChannelData?[0]
        else { return nil }

        let n = Int(outBuffer.frameLength)
        return (0..<n).map { src[$0] }
    }

    // MARK: - Chunking + gate

    /// Slice the accumulator into 160 ms chunks, apply the RMS gate, deliver.
    private func emitFixedChunks() {
        let chunkSize = Self.chunkSamples
        while accumulated.count >= chunkSize {
            var chunk = Array(accumulated[0..<chunkSize])
            accumulated.removeFirst(chunkSize)

            let silent = applyGate(&chunk)
            consecutiveSilentChunks = silent ? consecutiveSilentChunks + 1 : 0
            isStreamSilent = consecutiveSilentChunks >= 50

            let chunkObj = AudioChunk(
                samples: chunk, startSample: emittedSamples, silent: silent)
            emittedSamples += chunkSize
            onChunk?(chunkObj)
        }
    }

    /// Hysteresis RMS gate: below-speech stretches pass as true silence so
    /// the ASR cannot hallucinate on BGM-only passages.
    private func applyGate(_ samples: inout [Float]) -> Bool {
        var energy: Float = 0
        for s in samples { energy += s * s }
        let rms = (energy / Float(samples.count)).squareRoot()
        let now = Date()

        if gateSpeechActive {
            if rms >= gateOffThreshold {
                gateLastSpeechAt = now
            } else if now.timeIntervalSince(gateLastSpeechAt) >= gateHoldSeconds {
                gateSpeechActive = false
            }
        } else {
            if rms >= gateOnThreshold {
                gateSpeechActive = true
                gateLastSpeechAt = now
            }
        }

        if !gateSpeechActive {
            for i in samples.indices { samples[i] = 0 }
        }
        return !gateSpeechActive
    }
}
