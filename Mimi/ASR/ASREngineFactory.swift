import Foundation
import Synchronization

/// Builds the right engine for a session: native when the runtime + model
/// resolve, mock otherwise.
enum ASREngineFactory {
    /// Process-warm engine: the loaded model stays resident for the app's
    /// lifetime so starting a session after the first one skips the
    /// multi-second GGUF load + Metal pipeline compile. Locked statics — the
    /// warm-up runs off the main actor.
    private static let warm = Mutex<(engine: CrispASREngine?, path: String?)>((nil, nil))

    static func makeEngine(modelURL: URL?, allowMock: Bool) -> ASREngine? {
        if let modelURL {
            return warm.withLock { state in
                if let cached = state.engine {
                    if state.path == modelURL.path {
                        return cached
                    }
                    // Model file changed: retire the stale engine.
                    cached.close()
                    state.engine = nil
                    state.path = nil
                }
                if let engine = try? CrispASREngine(modelPath: modelURL) {
                    state.engine = engine
                    state.path = modelURL.path
                    return engine
                }
                return allowMock ? MockASREngine() : nil
            }
        }
        return allowMock ? MockASREngine() : nil
    }
}
