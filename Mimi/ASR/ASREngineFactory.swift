import Foundation
import Synchronization

/// Builds the right engine for a session: native when the runtime + model
/// resolve, mock otherwise.
enum ASREngineFactory {
    /// The warm-cache state, guarded by the factory `Mutex`.
    private struct WarmState {
        var engine: CrispASREngine?
        var path: String?
        /// Latched by `retireWarmEngine`: once retired, the factory hands out
        /// nothing, so an in-flight background warm-up cannot re-create a
        /// resident model after the quit teardown just freed it.
        var retired = false
    }

    /// Process-warm engine: the loaded model stays resident for the app's
    /// lifetime so starting a session after the first one skips the
    /// multi-second GGUF load + Metal pipeline compile. Locked statics — the
    /// warm-up runs off the main actor.
    private static let warm = Mutex(WarmState())

    static func makeEngine(modelURL: URL?, allowMock: Bool) -> ASREngine? {
        if let modelURL {
            return warm.withLock { state in
                // Retired (app quitting): a warm-up racing the quit teardown
                // must not load a new resident model.
                guard !state.retired else { return nil }
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

    /// Permanently closes the warm engine's C session (freeing the resident
    /// model and its Metal contexts) and clears the cache. Called at app quit
    /// — after the session teardown has drained — so the runtime's contexts
    /// are released before process exit instead of being reported alive at
    /// Metal device teardown. No-op when nothing is cached; closing an engine
    /// that never prepared only flips its finishing flag (no open session).
    ///
    /// The runtime also keeps a process-cached FireRedVAD model resident
    /// across sessions — the second Metal residency set alive at quit — so
    /// the cache is freed too. Only when a native engine existed: never
    /// dlopen the runtime just to shut it down. No-op when the runtime lacks
    /// the symbol. Retirement latches for the rest of the process: a warm-up
    /// that was in flight when the quit began cannot re-cache an engine
    /// behind it.
    static func retireWarmEngine() {
        var hadNativeEngine = false
        warm.withLock { state in
            hadNativeEngine = state.engine != nil
            state.engine?.close()
            state.engine = nil
            state.path = nil
            state.retired = true
        }
        if hadNativeEngine {
            (try? CrispASRLibrary.open())?.shutdown()
        }
    }

    /// Clears the retirement latch. Test-only: retirement is meant to hold
    /// for the rest of the process, but the factory suite shares one process
    /// and re-arms before every test.
    static func rearmWarmCacheForTesting() {
        warm.withLock { $0.retired = false }
    }
}
