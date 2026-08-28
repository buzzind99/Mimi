import Foundation

/// Streaming transcriber abstraction. The native engine wraps the CrispASR
/// C ABI; the mock keeps the whole pipeline testable without the runtime.
protocol Transcriber: AnyObject {
    /// Prepare the recognizer (model load) before the stream opens.
    func prepare() throws
    /// Open a streaming recognition session.
    func openStream() throws
    /// Push one 16 kHz mono chunk into the stream.
    func push(_ samples: [Float])
    /// Poll for the next available result (partial or final); nil = need more audio.
    func poll() -> ASREvent?
    /// Finish the stream and drain remaining finals. Strictly ordered teardown:
    /// capture stops first, then finish → drain → close → destroy.
    func finish() -> [ASREvent]
    /// Samples actually processed by the decoder (latency readback).
    var processedSamples: Int { get }
    var isMock: Bool { get }
    /// Called on an arbitrary thread when the engine hits a recoverable
    /// runtime failure (throttled); the app surfaces it as a session warning.
    var onEngineError: ((String) -> Void)? { get set }
}

enum ASREngineError: LocalizedError {
    case runtimeNotFound(String)
    case modelNotFound(String)
    case createFailed(String)
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound(let detail):
            return "ASR runtime not found (\(detail)). Build it with scripts/build_runtime.sh, or drop the GGUF into the models folder to use the mock."
        case .modelNotFound(let path):
            return "ASR model not found at \(path)."
        case .createFailed(let detail):
            return "Failed to create ASR recognizer: \(detail)"
        case .streamFailed(let detail):
            return "Failed to open ASR stream: \(detail)"
        }
    }
}

/// Pure-Swift stand-in used when the native runtime is unavailable. Emits
/// deterministic pseudo transcripts driven by the (gated) audio energy so the
/// full pipeline — buffering, translation, UI, export — stays exercisable.
/// The UI labels mock sessions clearly.
final class MockASREngine: Transcriber {
    let isMock = true
    var onEngineError: ((String) -> Void)?

    private static let canned = [
        "今日はいい天気ですね。",
        "これから配信を始めます、よろしくお願いします。",
        "新しいゲーム、みんな遊んだ？",
        "チャットの質問に答えていきますね。",
        "次の話題に移ります、面白いですよ。",
    ]

    private var speechChunksSeen = 0
    private var nextSentenceAt = 6
    private var pendingFinal: String?
    private var cannedIndex = 0
    private var totalSamples = 0
    private var lastFinalEnd = 0

    var processedSamples: Int { totalSamples }

    func prepare() throws {}
    func openStream() throws {}

    func push(_ samples: [Float]) {
        totalSamples += samples.count
        var energy: Float = 0
        for s in samples { energy += s * s }
        let rms = (energy / Float(max(1, samples.count))).squareRoot()
        if rms > 1e-3 {
            speechChunksSeen += 1
        }
        if pendingFinal == nil, speechChunksSeen >= nextSentenceAt {
            pendingFinal = Self.canned[cannedIndex % Self.canned.count]
            cannedIndex += 1
            nextSentenceAt = speechChunksSeen + Int.random(in: 5...12)
        }
    }

    func poll() -> ASREvent? {
        guard let text = pendingFinal else { return nil }
        pendingFinal = nil
        let end = totalSamples
        let start = lastFinalEnd
        lastFinalEnd = end
        return .final(text: text, startSample: start, endSample: end, lang: "ja")
    }

    func finish() -> [ASREvent] { [] }
}

/// Builds the right engine for a session: native when the runtime + model
/// resolve, mock otherwise.
enum ASREngineFactory {
    static func makeEngine(modelURL: URL?, allowMock: Bool) -> Transcriber? {
        if let modelURL, let engine = try? CrispASREngine(modelPath: modelURL) {
            return engine
        }
        return allowMock ? MockASREngine() : nil
    }
}
