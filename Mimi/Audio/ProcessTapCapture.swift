import AVFoundation
import CoreAudio
import Foundation

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
    case processTapFailed(OSStatus)
    case aggregateCreateFailed(OSStatus)
    case ioStartFailed(OSStatus)
    case noTappedProcesses
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access was denied. Grant access in System Settings → Privacy & Security → Microphone."
        case .processTapFailed(let status):
            return "Failed to create process tap (OSStatus \(status))."
        case .aggregateCreateFailed(let status):
            return "Failed to create aggregate device (OSStatus \(status))."
        case .ioStartFailed(let status):
            return "Failed to start capture IO (OSStatus \(status))."
        case .noTappedProcesses:
            return "No live processes to tap — the target app may have quit."
        case .formatUnavailable:
            return "Could not determine the tapped audio format."
        }
    }
}

/// Captures the target app's audio via a Core Audio Process Tap wrapped in a
/// private aggregate device.
///
/// Threading: the IO block only copies raw PCM into a lock-free ring buffer.
/// A worker queue drains it, converts to mono 16 kHz float32 with
/// `AVAudioConverter`, slices 160 ms chunks, applies the RMS gate, and calls
/// `onChunk`.
final class ProcessTapCapture {
    static let outputSampleRate: Double = 16_000
    static let chunkSamples = Int(outputSampleRate * 0.16)

    var onChunk: ((AudioChunk) -> Void)?
    var onIOError: ((CaptureError) -> Void)?

    /// RMS gate thresholds (float32 linear). Speech enter/exit hysteresis.
    var gateOnThreshold: Float = 1.2e-3
    var gateOffThreshold: Float = 0.6e-3
    var gateHoldSeconds: Double = 0.5

    private let ioQueue = DispatchQueue(label: "dev.mimi.capture.io", qos: .userInteractive)
    private let workerQueue = DispatchQueue(label: "dev.mimi.capture.worker", qos: .userInitiated)
    private let ring = RingBuffer(capacity: 1 << 22) // 4 MiB ≈ 1 s of 48k stereo f32

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var tappedPIDs: [pid_t] = []

    private var deviceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var accumulated: [Float] = []
    private var emittedSamples = 0
    private var gateSpeechActive = false
    private var gateLastSpeechAt: Date = .distantPast

    private(set) var isRunning = false

    // MARK: - Lifecycle

    func start(pids: [pid_t]) throws {
        guard !isRunning else { return }
        guard !pids.isEmpty else { throw CaptureError.noTappedProcesses }

        let processObjectIDs = pids.compactMap { pid -> AudioObjectID? in
            let id = Self.processObjectID(for: pid)
            return id > 0 ? id : nil
        }
        guard !processObjectIDs.isEmpty else { throw CaptureError.noTappedProcesses }

        tappedPIDs = pids

        let tapUUID = UUID()
        let description = CATapDescription(__stereoMixdownOfProcesses: processObjectIDs.map { NSNumber(value: $0) })
        description.name = "Mimi Tap \(tapUUID.uuidString)"
        description.uuid = tapUUID
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw CaptureError.processTapFailed(tapStatus) }
        tapID = tap

        let aggUID = "dev.mimi.aggregate.\(UUID().uuidString)"
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mimi Aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: 1,
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        var agg = AudioDeviceID(0)
        let aggStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &agg)
        guard aggStatus == noErr else {
            Self.destroyTap(tapID)
            throw CaptureError.aggregateCreateFailed(aggStatus)
        }
        aggregateID = agg

        deviceFormat = Self.queryInputFormat(aggregateID) ?? AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2)

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue, ioBlock)
        guard ioStatus == noErr, ioProcID != nil else {
            teardownDevices()
            throw CaptureError.ioStartFailed(ioStatus)
        }

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            teardownDevices()
            throw CaptureError.ioStartFailed(startStatus)
        }

        isRunning = true
        workerQueue.async { [weak self] in self?.drainLoop() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        teardownDevices()
    }

    /// Re-target the tap onto a new pid set (helpers spawned/died). The
    /// aggregate + tap are rebuilt; session sample numbering continues.
    func retarget(pids: [pid_t]) throws {
        guard isRunning else { return }
        stop()
        // Small delay so the old IO cycle fully stops before re-creating.
        Thread.sleep(forTimeInterval: 0.05)
        try start(pids: pids)
    }

    var currentPIDs: [pid_t] { tappedPIDs }

    // MARK: - IO (real-time side)

    /// The IO block: copy PCM into the ring buffer. No allocations, no locks.
    private lazy var ioBlock: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
        guard let self else { return }
        let abl = inputData.pointee
        let nBuffers = Int(abl.mNumberBuffers)
        guard nBuffers > 0 else { return }

        var buffers = [(UnsafeRawPointer, Int)]()
        var frames = 0
        var channels = 0
        var payloadBytes = 0
        withUnsafePointer(to: abl.mBuffers) { ptr in
            ptr.withMemoryRebound(to: AudioBuffer.self, capacity: nBuffers) { typed in
                let first = typed[0]
                guard let data = first.mData else { return }
                channels = Int(first.mNumberChannels)
                frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(1, channels)
                for i in 0..<nBuffers {
                    let buf = typed[i]
                    if let bufData = buf.mData {
                        buffers.append((UnsafeRawPointer(bufData), Int(buf.mDataByteSize)))
                        payloadBytes += Int(buf.mDataByteSize)
                    }
                }
            }
        }
        guard frames > 0, channels > 0, payloadBytes > 0 else { return }

        let headerSize = MemoryLayout<RingFrameHeader>.size
        let total = headerSize + payloadBytes
        // Reserve the whole block up front so header and payload can never be
        // split across an overflow (a dropped payload would desync the reader).
        guard self.ring.freeBytes >= total else {
            self.ring.noteDropped(total)
            return
        }

        let header = RingFrameHeader(
            frames: UInt32(frames), nBuffers: UInt32(nBuffers),
            sampleRate: self.lockedDeviceSampleRate, channels: UInt32(channels),
            payloadBytes: UInt32(payloadBytes), interleaved: nBuffers <= 1 ? 1 : 0)
        withUnsafePointer(to: header) { headerPtr in
            _ = self.ring.write(UnsafeRawPointer(headerPtr), count: headerSize)
        }
        for (src, size) in buffers {
            _ = self.ring.write(src, count: size)
        }
    }

    /// Sample rate read once at start (locked for the session).
    private var lockedDeviceSampleRate: Double {
        deviceFormat?.sampleRate ?? 48_000
    }

    // MARK: - Worker side

    private func drainLoop() {
        let headerSize = MemoryLayout<RingFrameHeader>.size
        var scratch = RingFrameHeader(
            frames: 0, nBuffers: 0, sampleRate: 0, channels: 0,
            payloadBytes: 0, interleaved: 0)
        var payload = [Float]()
        let sleepUS: useconds_t = 2_000

        while isRunning {
            if ring.availableBytes < headerSize {
                usleep(sleepUS)
                continue
            }
            // Peek the header without consuming: only proceed once the whole
            // frame (header + payload) is buffered, otherwise a payload still
            // being written would desync the stream.
            guard ring.peek(into: &scratch, count: headerSize) == headerSize else {
                usleep(sleepUS)
                continue
            }
            guard Self.isPlausibleHeader(scratch) else {
                ring.dropBuffered()
                continue
            }
            if ring.availableBytes < headerSize + Int(scratch.payloadBytes) {
                usleep(sleepUS)
                continue
            }
            ring.skip(headerSize)

            let payloadFloats = Int(scratch.payloadBytes) / MemoryLayout<Float>.size
            if payload.count < payloadFloats {
                payload = [Float](repeating: 0, count: payloadFloats)
            }
            let read = payload.withUnsafeMutableBytes { raw -> Int in
                guard raw.count >= Int(scratch.payloadBytes), let base = raw.baseAddress else { return 0 }
                return ring.read(into: base, count: Int(scratch.payloadBytes))
            }
            guard read == Int(scratch.payloadBytes) else {
                ring.dropBuffered()
                continue
            }

            consume(
                floats: payload, frames: Int(scratch.frames),
                channels: Int(scratch.channels),
                nBuffers: Int(scratch.nBuffers), sampleRate: scratch.sampleRate,
                interleaved: scratch.interleaved != 0)
        }
    }

    /// Sanity-check a peeked header. A mismatch means the ring is desynced
    /// (garbage interpreted as a header); the buffered data is discarded.
    private static func isPlausibleHeader(_ h: RingFrameHeader) -> Bool {
        h.frames > 0 && h.frames <= 65_536
            && h.channels > 0 && h.channels <= 8
            && h.nBuffers > 0 && h.nBuffers <= 8
            && h.sampleRate >= 8_000 && h.sampleRate <= 384_000
            && h.payloadBytes > 0 && h.payloadBytes <= 65_536 * 8 * 4
            && h.interleaved <= 1
    }

    /// Convert one delivered block to mono 16 kHz and emit fixed chunks.
    private func consume(
        floats: [Float], frames: Int, channels: Int, nBuffers: Int,
        sampleRate: Double, interleaved: Bool
    ) {
        guard frames > 0, sampleRate > 0 else { return }

        // Deinterleaved payloads are N mono buffers; the per-buffer channel
        // count is in `channels`, so the format spans channels * nBuffers.
        let totalChannels = interleaved ? channels : channels * max(1, nBuffers)
        guard let deviceFormat = makeFormat(
            sampleRate: sampleRate, channels: totalChannels, interleaved: interleaved)
        else {
            print("unsupported tap format: sr=\(sampleRate) ch=\(totalChannels) inter=\(interleaved)")
            return
        }
        guard let converter = ensureConverter(from: deviceFormat) else {
            onIOError?(.formatUnavailable)
            return
        }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        inBuffer.frameLength = AVAudioFrameCount(frames)
        let framesPerBuffer = interleaved ? 1 : frames
        if let floatChannels = inBuffer.floatChannelData {
            for ch in 0..<min(totalChannels, Int(inBuffer.format.channelCount)) {
                for f in 0..<frames {
                    let idx: Int
                    if interleaved {
                        idx = f * channels + ch
                    } else {
                        let bufferIndex = ch / max(1, channels)
                        let channelInBuffer = ch % max(1, channels)
                        idx = bufferIndex * framesPerBuffer * max(1, channels)
                            + channelInBuffer * framesPerBuffer + f
                    }
                    floatChannels[ch][f] = floats[idx]
                }
            }
        }

        let ratio = Self.outputSampleRate / sampleRate
        let outCapacity = AVAudioFrameCount(Double(frames) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return }

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
        if status == .error || conversionError != nil {
            onIOError?(.formatUnavailable)
            return
        }

        if let chunkSamples = outBuffer.floatChannelData?[0] {
            let n = Int(outBuffer.frameLength)
            for i in 0..<n {
                accumulated.append(chunkSamples[i])
            }
        }
        emitFixedChunks()
    }

    private lazy var outputFormat: AVAudioFormat = AVAudioFormat(
        standardFormatWithSampleRate: Self.outputSampleRate, channels: 1)!

    private var cachedConverterKey: String?
    private func ensureConverter(from format: AVAudioFormat) -> AVAudioConverter? {
        let key = format.description
        if let cachedConverterKey, cachedConverterKey == key, let converter {
            return converter
        }
        guard let new = AVAudioConverter(from: format, to: outputFormat) else {
            print("AVAudioConverter creation failed: from=\(format) to=\(outputFormat)")
            return nil
        }
        converter = new
        cachedConverterKey = key
        return new
    }

    private func makeFormat(sampleRate: Double, channels: Int, interleaved: Bool) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(max(1, channels)), interleaved: interleaved)
    }

    /// Slice the accumulator into 160 ms chunks, apply the RMS gate, deliver.
    private func emitFixedChunks() {
        let chunkSize = Self.chunkSamples
        while accumulated.count >= chunkSize {
            var chunk = Array(accumulated[0..<chunkSize])
            accumulated.removeFirst(chunkSize)

            let silent = applyGate(&chunk)
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

    // MARK: - Teardown

    private func teardownDevices() {
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            Self.destroyTap(tapID)
            tapID = 0
        }
        ring.reset()
        accumulated.removeAll(keepingCapacity: true)
    }

    private static func destroyTap(_ id: AudioObjectID) {
        AudioHardwareDestroyProcessTap(id)
    }

    // MARK: - Core Audio helpers

    static func processObjectID(for pid: pid_t) -> AudioObjectID {
        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &objectID)
        }
        return status == noErr ? objectID : 0
    }

    private static func queryInputFormat(_ device: AudioDeviceID) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &asbd) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, asbd.mSampleRate > 0 else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(max(1, Int(asbd.mChannelsPerFrame))), interleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
    }
}

/// Wire format for one IO cycle copied into the ring buffer.
/// `payloadBytes` is authoritative (sum of every buffer written after the
/// header); `interleaved` is 1 when the payload is a single interleaved
/// buffer, 0 when it is N mono buffers.
struct RingFrameHeader {
    var frames: UInt32
    var nBuffers: UInt32
    var sampleRate: Float64
    var channels: UInt32
    var payloadBytes: UInt32
    var interleaved: UInt32
}
