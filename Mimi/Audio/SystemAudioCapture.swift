import AVFoundation
import Foundation
import ScreenCaptureKit

/// Emitted mono 16 kHz chunk (160 ms = 2,560 samples). `samples` is a value
/// type; safe to hand across queues.
struct AudioChunk: Sendable {
    let samples: [Float]
    /// Session-relative sample offset of the first sample.
    let startSample: Int
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
/// delegate downmixes/resamples when needed, slices 160 ms chunks, and calls
/// `onChunk` on that queue. Silence suppression (VAD + RMS backstop) is the
/// engine's job.
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    static let outputSampleRate: Double = 16_000
    static let chunkSamples = Int(outputSampleRate * 0.16)

    var onChunk: ((AudioChunk) -> Void)?
    var onIOError: ((CaptureError) -> Void)?

    private let outputQueue = DispatchQueue(
        label: "dev.mimi.capture.sck", qos: .userInteractive)

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var cachedConverterRate: Double = 0
    private var accumulated: [Float] = []
    /// Read cursor into `accumulated`: consumed chunks compact once per
    /// callback instead of a `removeFirst` memmove per chunk.
    private var accumulatedStart = 0
    private var emittedSamples = 0

    private(set) var isRunning = false

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
        accumulatedStart = 0
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

    /// PCM buffers reused across chunks (reallocated only if a future
    /// source rate/duration needs more capacity).
    private var cachedInputFormat: AVAudioFormat?
    private var inBuffer: AVAudioPCMBuffer?
    private var outBuffer: AVAudioPCMBuffer?

    private func resample(_ mono: [Float], from rate: Double) -> [Float]? {
        if cachedConverterRate != rate {
            guard let inFormat = AVAudioFormat(
                standardFormatWithSampleRate: rate, channels: 1),
                let newConverter = AVAudioConverter(from: inFormat, to: outputFormat)
            else {
                print("AVAudioConverter creation failed: \(rate) → \(outputFormat)")
                return nil
            }
            converter = newConverter
            cachedInputFormat = inFormat
            cachedConverterRate = rate
            inBuffer = nil
            outBuffer = nil
        }
        guard let converter, let inFormat = cachedInputFormat else { return nil }

        if inBuffer == nil || inBuffer!.frameCapacity < AVAudioFrameCount(mono.count) {
            inBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(mono.count))
        }
        guard let inBuffer, inBuffer.floatChannelData != nil else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(mono.count)
        if let dst = inBuffer.floatChannelData?[0] {
            mono.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: mono.count)
            }
        }

        let ratio = Self.outputSampleRate / rate
        let outCapacity = AVAudioFrameCount(Double(mono.count) * ratio) + 32
        if outBuffer == nil || outBuffer!.frameCapacity < outCapacity {
            outBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: outCapacity)
        }
        guard let outBuffer else { return nil }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            fed = true
            return self.inBuffer
        }
        guard status != .error, conversionError == nil,
            let src = outBuffer.floatChannelData?[0]
        else { return nil }

        let n = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: src, count: n))
    }

    // MARK: - Chunking

    /// Slice the accumulator into 160 ms chunks and deliver.
    private func emitFixedChunks() {
        let chunkSize = Self.chunkSamples
        while accumulated.count - accumulatedStart >= chunkSize {
            let chunk = Array(accumulated[accumulatedStart..<accumulatedStart + chunkSize])
            accumulatedStart += chunkSize

            let chunkObj = AudioChunk(
                samples: chunk, startSample: emittedSamples)
            emittedSamples += chunkSize
            onChunk?(chunkObj)
        }
        // One compaction per callback (not per chunk): amortizes the
        // memmove when several chunks arrive together.
        if accumulatedStart > 0 {
            accumulated.removeFirst(accumulatedStart)
            accumulatedStart = 0
        }
    }
}
