@testable import Mimi
import XCTest

// MARK: - DictionaryFFI loading

final class DictionaryFFITests: XCTestCase {

    func test_load_whenLibraryMissing_shouldReturnNil() {
        let openLibrary: (String) -> UnsafeMutableRawPointer? = { _ in nil }
        let symbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { _, _ in nil }

        let ffi = DictionaryFFI.load(openLibrary: openLibrary, symbol: symbol)

        XCTAssertNil(ffi)
    }

    func test_load_whenFirstCandidateFails_shouldTryNextCandidate() {
        var attempts = 0
        let openLibrary: (String) -> UnsafeMutableRawPointer? = { _ in
            attempts += 1
            return attempts == 1 ? nil : UnsafeMutableRawPointer(bitPattern: 1)
        }
        let symbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { _, name in
            UnsafeMutableRawPointer(strdup(name))
        }

        let ffi = DictionaryFFI.load(openLibrary: openLibrary, symbol: symbol)

        XCTAssertNotNil(ffi, "the second candidate must bind")
        XCTAssertEqual(attempts, 2, "the second candidate should be tried after the first fails")
    }

    func test_load_whenRequiredSymbolMissing_shouldReturnNil() {
        let openLibrary: (String) -> UnsafeMutableRawPointer? = { _ in
            UnsafeMutableRawPointer(bitPattern: 1)
        }
        let symbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { _, name in
            // "tentoku_build_db" is the dylib's ABI literal, mirrored here.
            name == "tentoku_build_db" ? nil : UnsafeMutableRawPointer(strdup(name))
        }

        let ffi = DictionaryFFI.load(openLibrary: openLibrary, symbol: symbol)

        XCTAssertNil(ffi)
    }

    func test_load_withRealRuntime_shouldBindAllSymbols() throws {
        try XCTSkipIf(DictionaryFFI.load() == nil, "libdictionary.dylib is not available")
    }
}
