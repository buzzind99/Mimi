import Foundation
@testable import Mimi

/// Thread-safe sink for `onEngineError` (called from the engine's job
/// queues, not the test thread).
final class ErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ message: String) {
        lock.withLock { messages.append(message) }
    }

    var all: [String] {
        lock.withLock { messages }
    }
}

/// Scripted `CrispASRLibraryAPI` double. Ordered replies repeat their
/// last element; optional gates pin async interleavings (a VAD result
/// held inside the fake while a decode closes its generation). Knobs
/// script the session handshake (`openSessionResult`, `detectBackendResult`)
/// and a missing dispatcher ABI (`.unavailable`).
final class FakeCrispASRLibrary: CrispASRLibraryAPI, @unchecked Sendable {
    enum VADReply {
        case spans([(start: Float, end: Float)])
        case speechless
        case failure(Int32)
        /// The dispatcher ABI is unavailable — `vadSlices` returns nil.
        case unavailable
    }

    struct TranscribeCall {
        let pcmCount: Int
        let pcm: [Float]
        let languageCode: String
    }

    private let lock = NSLock()

    var vadModelPathValue: String? = "/tmp/fake-firered-vad.gguf"
    var vadReplies: [VADReply] = [.speechless]
    var transcribeReplies: [String?] = [""]
    var recordTranscribePcm = true
    /// Return value for `openSession` — nil fails the engine's `prepare`.
    var openSessionResult: OpaquePointer? = OpaquePointer(bitPattern: 0x1A55_1E55)
    /// Non-nil → the value `detectBackend` reports; nil → the engine's
    /// fallback backend is exercised (the protocol default).
    var detectBackendResult: String?
    /// Set → `vadSlices` marks the call entered and blocks until released.
    var vadHoldSemaphore: DispatchSemaphore?
    /// Set → `transcribeText` marks the call entered and blocks until released.
    var transcribeHoldSemaphore: DispatchSemaphore?

    private(set) var vadCalls: [[Float]] = []
    private(set) var vadEntered = false
    private(set) var transcribeCalls: [TranscribeCall] = []
    private(set) var transcribeEntered = false
    private(set) var vadFreeCount = 0
    private(set) var gpuBackends: [String] = []
    private(set) var openSessionCount = 0
    private(set) var openSessionBackends: [String] = []
    private(set) var closeSessionCount = 0

    var vadModelPath: String? {
        vadModelPathValue
    }

    func setGpuBackend(_ name: String) {
        lock.withLock { gpuBackends.append(name) }
    }

    func openSession(modelPath: String, backend: String) -> OpaquePointer? {
        lock.withLock {
            openSessionCount += 1
            openSessionBackends.append(backend)
        }
        return openSessionResult
    }

    func closeSession(_ session: OpaquePointer?) {
        lock.withLock { closeSessionCount += 1 }
    }

    func transcribeText(
        session: OpaquePointer?, pcm: borrowing Span<Float>, languageCode: String
    ) -> String? {
        let pcmCopy = pcm.withUnsafeBufferPointer { Array($0) }
        if let hold = transcribeHoldSemaphore {
            lock.withLock { transcribeEntered = true }
            hold.wait()
        }
        lock.withLock {
            transcribeCalls.append(TranscribeCall(
                pcmCount: pcmCopy.count,
                pcm: recordTranscribePcm ? pcmCopy : [],
                languageCode: languageCode
            ))
        }
        let index = min(transcribeCalls.count - 1, transcribeReplies.count - 1)
        return transcribeReplies[index]
    }

    func vadSlices(
        modelPath: String,
        pcm: borrowing Span<Float>,
        parameters: CrispASRVADParameters
    ) -> (count: Int32, spans: UnsafeMutablePointer<Float>?)? {
        lock.withLock { vadCalls.append(pcm.withUnsafeBufferPointer { Array($0) }) }
        if let hold = vadHoldSemaphore {
            lock.withLock { vadEntered = true }
            hold.wait()
        }
        let reply = vadReplies[min(vadCalls.count - 1, vadReplies.count - 1)]
        switch reply {
        case .unavailable:
            return nil
        case let .failure(code):
            return (code, nil)
        case .speechless:
            return (0, nil)
        case let .spans(pairs):
            let spans = UnsafeMutablePointer<Float>.allocate(capacity: pairs.count * 2)
            for (index, pair) in pairs.enumerated() {
                spans[2 * index] = pair.start
                spans[2 * index + 1] = pair.end
            }
            return (Int32(pairs.count), spans)
        }
    }

    func vadFree(_ spans: UnsafeMutablePointer<Float>?) {
        spans?.deallocate()
        lock.withLock { vadFreeCount += 1 }
    }

    func detectBackend(modelPath: String) -> String? {
        detectBackendResult
    }
}
