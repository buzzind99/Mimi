import Foundation

/// Builds the right engine for a session: native when the runtime + model
/// resolve, mock otherwise.
enum ASREngineFactory {
    /// Process-warm engine: the loaded model stays resident for the app's
    /// lifetime so starting a session after the first one skips the
    /// multi-second GGUF load + Metal pipeline compile. Locked statics — the
    /// warm-up runs off the main actor.
    private static let lock = NSLock()
    private static var warm: CrispASREngine?
    private static var warmModelPath: String?

    static func makeEngine(modelURL: URL?, allowMock: Bool) -> ASREngine? {
        if let modelURL {
            lock.lock()
            defer { lock.unlock() }
            if let cached = warm {
                if warmModelPath == modelURL.path {
                    return cached
                }
                // Model file changed: retire the stale engine.
                cached.close()
                warm = nil
                warmModelPath = nil
            }
            if let engine = try? CrispASREngine(modelPath: modelURL) {
                warm = engine
                warmModelPath = modelURL.path
                return engine
            }
        }
        return allowMock ? MockASREngine() : nil
    }
}
