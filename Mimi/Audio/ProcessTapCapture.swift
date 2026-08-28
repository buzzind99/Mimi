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

        var header = RingFrameHeader(frames: 0, nBuffers: UInt32(nBuffers), sampleRate: 0, channels: 0)
        var buffers = [(UnsafeRawPointer, Int)]()
        withUnsafePointer(to: abl.mBuffers) { ptr in
            ptr.withMemoryRebound(to: AudioBuffer.self, capacity: nBuffers) { typed in
                let first = typed[0]
                guard let data = first.mData else { return }
                header.channels = first.mNumberChannels
                header.frames = UInt32(Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(1, Int(first.mNumberChannels)))
                for i in 0..<nBuffers {
                    let buf = typed[i]
                    if let bufData = buf.mData {
                        buffers.append((UnsafeRawPointer(bufData), Int(buf.mDataByteSize)))
                    }
                }
            }
        }
        guard header.frames > 0, header.channels > 0, !buffers.isEmpty else { return }
        header.sampleRate = self.lockedDeviceSampleRate

        let headerSize = MemoryLayout<RingFrameHeader>.size
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
        var header = RingFrameHeader(frames: 0, nBuffers: 0, sampleRate: 0, channels: 0)
        var payload = [Float]()
        let sleepUS: useconds_t = 2_000

        while isRunning {
            if ring.availableBytes < headerSize {
                usleep(sleepUS)
                continue
            }
            var scratch = header
            let got = withUnsafeMutableBytes(of: &scratch) { ring.read(into: $0.baseAddress!, count: headerSize) }
            guard got == headerSize else { usleep(sleepUS); continue }
            header = scratch

            let payloadFloats = Int(header.frames) * max(1, Int(header.channels))
            let byteCount = payloadFloats * MemoryLayout<Float>.size
            if payload.count < payloadFloats {
                payload = [Float](repeating: 0, count: payloadFloats)
            }
            let read = payload.withUnsafeMutableBytes { raw -> Int in
                guard raw.count >= byteCount, let base = raw.baseAddress else { return 0 }
                return ring.read(into: base, count: byteCount)
            }
            guard read == byteCount else { usleep(sleepUS); continue }

            consume(
                floats: payload, frames: Int(header.frames),
                channels: max(1, Int(header.channels)),
                nBuffers: Int(header.nBuffers), sampleRate: header.sampleRate)
        }
    }

    /// Convert one delivered block to mono 16 kHz and emit fixed chunks.
    private func consume(
        floats: [Float], frames: Int, channels: Int, nBuffers: Int, sampleRate: Double
    ) {
        guard frames > 0, sampleRate > 0 else { return }
        let interleaved = nBuffers <= 1

        guard let deviceFormat = makeFormat(
            sampleRate: sampleRate, channels: channels, interleaved: interleaved)
        else { return }
        let converter = ensureConverter(from: deviceFormat)

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        inBuffer.frameLength = AVAudioFrameCount(frames)
        let framesPerBuffer = interleaved ? 1 : frames
        if let floatChannels = inBuffer.floatChannelData {
            for ch in 0..<min(channels, Int(inBuffer.format.channelCount)) {
                for f in 0..<frames {
                    let idx: Int
                    if interleaved {
                        idx = f * channels + ch
                    } else {
                        idx = (ch % nBuffers) * framesPerBuffer + f
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
    private func ensureConverter(from format: AVAudioFormat) -> AVAudioConverter {
        let key = format.description
        if let cachedConverterKey, cachedConverterKey == key, let converter {
            return converter
        }
        let new = AVAudioConverter(from: format, to: outputFormat)!
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
        var pidValue = Int32(pid)
        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, pidPtr)
        }
        if status == noErr {
            objectID = AudioObjectID(pidValue)
        }
        return objectID
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
struct RingFrameHeader {
    var frames: UInt32
    var nBuffers: UInt32
    var sampleRate: Float64
    var channels: UInt32
}
