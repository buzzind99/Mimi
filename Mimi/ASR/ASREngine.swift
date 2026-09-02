import Foundation

/// Streaming transcriber abstraction. The native engine wraps the CrispASR
/// C ABI; the mock keeps the whole pipeline testable without the runtime.
protocol ASREngine: AnyObject, Sendable {
    /// Prepare the recognizer (model load) before the stream opens.
    func prepare() throws
    /// Open a streaming recognition session.
    func openStream() throws
    /// Push one 16 kHz mono chunk into the stream.
    func push(_ samples: [Float])
    /// Poll for the next available result (partial or final); nil = need more audio.
    func poll() -> ASREvent?
    /// Finish the stream and drain remaining finals. Strictly ordered teardown:
    /// capture stops first, then finish → drain. The engine stays warm — the
    /// loaded model is reused by the next session.
    func finish() -> [ASREvent]
    /// Samples actually processed by the decoder (latency readback).
    var processedSamples: Int { get }
    /// Samples pushed into the stream but not necessarily processed yet.
    /// Polled on the main actor (60 ms tick) instead of hopping per chunk.
    var pushedSamples: Int { get }
    var isMock: Bool { get }
    /// Called on an arbitrary thread when the engine hits a recoverable
    /// runtime failure (throttled); the app surfaces it as a session warning.
    var onEngineError: ((String) -> Void)? { get set }
}

enum ASREngineError: LocalizedError {
    case runtimeNotFound(String)
    case modelNotFound(String)
    case createFailed(String)

    var errorDescription: String? {
        switch self {
        case let .runtimeNotFound(detail):
            return "ASR runtime not found (\(detail)). Build it with scripts/build_runtime.sh, or drop the GGUF into the models folder to use the mock."
        case let .modelNotFound(path):
            return "ASR model not found at \(path)."
        case let .createFailed(detail):
            return "Failed to create ASR recognizer: \(detail)"
        }
    }
}
