@testable import Mimi
import XCTest

/// Pins all three `ASREngineError` descriptions (surfaced verbatim to the
/// user via `AppModel`'s `onEngineError` / `.needsModel` paths).
final class ASREngineErrorTests: XCTestCase {

    func test_errorDescription_whenRuntimeNotFound_shouldIncludeBuildHint() {
        let error = ASREngineError.runtimeNotFound("dlopen failed: image not found")

        XCTAssertEqual(
            error.errorDescription,
            "ASR runtime not found (dlopen failed: image not found). Build it with "
                + "scripts/build_runtime.sh, or drop the GGUF into the models folder to use the mock."
        )
    }

    func test_errorDescription_whenModelNotFound_shouldIncludePath() {
        let error = ASREngineError.modelNotFound("/tmp/nope.gguf")

        XCTAssertEqual(error.errorDescription, "ASR model not found at /tmp/nope.gguf.")
    }

    func test_errorDescription_whenCreateFailed_shouldIncludeDetail() {
        let error = ASREngineError.createFailed("crispasr_session_open_explicit failed (backend qwen3)")

        XCTAssertEqual(
            error.errorDescription,
            "Failed to create ASR recognizer: crispasr_session_open_explicit failed (backend qwen3)"
        )
    }
}
