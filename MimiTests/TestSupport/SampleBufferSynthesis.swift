import CoreMedia
import Foundation
@testable import Mimi

/// Synthesizes `CMSampleBuffer`s with PCM payloads for exercising
/// `SystemAudioCapture`'s delegate data path without ScreenCaptureKit
/// (`CMAudioFormatDescriptionCreate` + `CMBlockBuffer` + `CMSampleBufferCreate`).
///
/// Payload values are deterministic so tests can compute expected downmix and
/// resample results exactly: channel `c`, frame `f` holds `f + c * 10_000`
/// (float32-exact for f < 10_000 and c < 9; int16 writes the same values
/// truncated). A stereo deinterleaved downmix of frame `f` is therefore
/// `f + 5_000`, a mono buffer is just `f`.
enum SampleBufferSynthesis {

    /// Thrown when a Core Media call fails during synthesis.
    struct Error: Swift.Error, CustomStringConvertible {
        let operation: String
        let status: OSStatus

        var description: String {
            "\(operation) failed with OSStatus \(status)"
        }
    }

    /// Payload encodings, ordered by what the capture pipeline accepts.
    enum PayloadFormat {
        /// The supported input: float32 LinearPCM.
        case float32
        /// PCM but not float32 — drives `extractMono`'s unsupported-format
        /// branch → `onIOError(.formatUnavailable)`.
        case int16
        /// Non-LinearPCM format ID — drives the sample callback's non-PCM
        /// guard before any payload extraction.
        case nonPCM
    }

    /// Builds a sample buffer with the requested layout.
    ///
    /// - Parameters:
    ///   - frames: sample frames per channel; `0` exercises the zero-frame
    ///     guard in the sample callback.
    ///   - channels: 1 for mono; ≥ 2 exercises the downmix in either layout.
    ///   - sampleRate: 16 kHz passes through `SystemAudioCapture` untouched;
    ///     any other rate drives its resample fallback.
    ///   - interleaved: one N-channel buffer vs N one-channel buffers.
    ///   - format: payload encoding (see `PayloadFormat`).
    ///   - dataReady: `false` exercises the data-not-ready guard in the
    ///     sample callback.
    ///   - withFormatDescription: `false` creates the buffer without a
    ///     format description, exercising the sample callback's
    ///     missing-description guard.
    static func make(
        frames: Int,
        channels: Int = 1,
        sampleRate: Double = SystemAudioCapture.outputSampleRate,
        interleaved: Bool = true,
        format: PayloadFormat = .float32,
        dataReady: Bool = true,
        withFormatDescription: Bool = true
    ) throws -> CMSampleBuffer {
        let formatDescription: CMFormatDescription? = try withFormatDescription
            ? makeFormatDescription(
                channels: channels, sampleRate: sampleRate, interleaved: interleaved, format: format
            )
            : nil
        let payload = makePayload(
            frames: frames, channels: channels, interleaved: interleaved, format: format
        )
        let blockBuffer = try makeBlockBuffer(payload)

        var sampleBuffer: CMSampleBuffer?
        let status: OSStatus
        if dataReady {
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: frames,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
        } else {
            status = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: false,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleCount: frames,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
        }
        guard status == noErr, let sampleBuffer else {
            throw Error(operation: "CMSampleBufferCreate", status: status)
        }
        return sampleBuffer
    }

    // MARK: - Pieces

    private static func makeFormatDescription(
        channels: Int, sampleRate: Double, interleaved: Bool, format: PayloadFormat
    ) throws -> CMFormatDescription {
        var asbd: AudioStreamBasicDescription
        switch format {
        case .float32, .int16:
            let bytesPerSample = format == .float32 ? 4 : 2
            var flags = format == .float32
                ? kAudioFormatFlagIsFloat
                : kAudioFormatFlagIsSignedInteger
            flags |= kAudioFormatFlagIsPacked
            if !interleaved {
                flags |= kAudioFormatFlagIsNonInterleaved
            }
            asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags,
                mBytesPerPacket: UInt32(bytesPerSample * channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(interleaved ? bytesPerSample * channels : bytesPerSample),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: UInt32(bytesPerSample * 8),
                mReserved: 0
            )
        case .nonPCM:
            asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0,
                mBytesPerPacket: 16,
                mFramesPerPacket: 1,
                mBytesPerFrame: 16,
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 0,
                mReserved: 0
            )
        }

        var formatDescription: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw Error(operation: "CMAudioFormatDescriptionCreate", status: status)
        }
        return formatDescription
    }

    /// Payload bytes laid out the way CoreAudio reads the format: frame-major
    /// (L R L R …) when interleaved, channel-major (L L L … R R R …) when
    /// deinterleaved. Empty for zero-frame buffers; opaque filler for non-PCM
    /// (its payload is never extracted — the format ID trips first).
    private static func makePayload(
        frames: Int, channels: Int, interleaved: Bool, format: PayloadFormat
    ) -> [UInt8] {
        let bytesPerSample: Int
        switch format {
        case .float32: bytesPerSample = 4
        case .int16: bytesPerSample = 2
        case .nonPCM: return [UInt8](repeating: 0xA5, count: max(frames, 1) * 16)
        }

        var payload = [UInt8](repeating: 0, count: frames * channels * bytesPerSample)
        payload.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for c in 0 ..< channels {
                for f in 0 ..< frames {
                    let index = interleaved ? f * channels + c : c * frames + f
                    if format == .int16 {
                        let dst = base.assumingMemoryBound(to: Int16.self)
                        dst[index] = Int16(truncatingIfNeeded: f + c * 10000)
                    } else {
                        let dst = base.assumingMemoryBound(to: Float.self)
                        dst[index] = Float(f + c * 10000)
                    }
                }
            }
        }
        return payload
    }

    private static func makeBlockBuffer(_ payload: [UInt8]) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        // Zero-frame buffers still need a (minimum 1-byte) block buffer —
        // CMBlockBufferCreateWithMemoryBlock rejects zero-length blocks.
        let blockLength = max(payload.count, 1)
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: blockLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: blockLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw Error(operation: "CMBlockBufferCreateWithMemoryBlock", status: status)
        }
        guard !payload.isEmpty else { return blockBuffer }

        var replaceStatus = kCMBlockBufferNoErr
        payload.withUnsafeBytes { raw in
            replaceStatus = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: payload.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            throw Error(operation: "CMBlockBufferReplaceDataBytes", status: replaceStatus)
        }
        return blockBuffer
    }
}
