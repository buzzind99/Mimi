@testable import Mimi
import Testing

/// Pins all three `ASREngineError` descriptions (surfaced verbatim to the
/// user via `AppModel`'s `onEngineError` / `.needsModel` paths).
@Suite("ASREngineError")
struct ASREngineErrorTests {

    @Test("runtimeNotFound's description includes the build hint")
    func runtimeNotFoundIncludesBuildHint() {
        let error = ASREngineError.runtimeNotFound("dlopen failed: image not found")

        #expect(
            error.errorDescription
                == "ASR runtime not found (dlopen failed: image not found). Build it with "
                + "scripts/build_runtime.sh, or drop the GGUF into the models folder to use the mock."
        )
    }

    @Test("modelNotFound's description includes the path")
    func modelNotFoundIncludesPath() {
        let error = ASREngineError.modelNotFound("/tmp/nope.gguf")

        #expect(error.errorDescription == "ASR model not found at /tmp/nope.gguf.")
    }

    @Test("createFailed's description includes the detail")
    func createFailedIncludesDetail() {
        let error = ASREngineError.createFailed("crispasr_session_open_explicit failed (backend qwen3)")

        #expect(
            error.errorDescription
                == "Failed to create ASR recognizer: crispasr_session_open_explicit failed (backend qwen3)"
        )
    }
}
