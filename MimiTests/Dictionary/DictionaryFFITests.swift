import Foundation
@testable import Mimi
import Testing

// MARK: - DictionaryFFI loading

@Suite("DictionaryFFI loading")
struct DictionaryFFITests {

    @Test("returns nil when the library is missing")
    func libraryMissing() {
        let openLibrary: (String) -> UnsafeMutableRawPointer? = { _ in nil }
        let symbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { _, _ in nil }

        let ffi = DictionaryFFI.load(openLibrary: openLibrary, symbol: symbol)

        #expect(ffi == nil)
    }

    @Test("tries the next candidate after a failed load")
    func firstCandidateFailsTriesNext() {
        var attempts = 0
        let openLibrary: (String) -> UnsafeMutableRawPointer? = { _ in
            attempts += 1
            return attempts == 1 ? nil : UnsafeMutableRawPointer(bitPattern: 1)
        }
        let symbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { _, name in
            UnsafeMutableRawPointer(strdup(name))
        }

        let ffi = DictionaryFFI.load(openLibrary: openLibrary, symbol: symbol)

        #expect(ffi != nil, "the second candidate must bind")
        #expect(attempts == 2, "the second candidate should be tried after the first fails")
    }

    @Test("returns nil when the open symbol is missing")
    func openSymbolMissing() {
        let openLibrary: (String) -> UnsafeMutableRawPointer? = { _ in
            UnsafeMutableRawPointer(bitPattern: 1)
        }
        let symbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { _, name in
            // "dictionary_open" is the dylib's ABI literal, mirrored here.
            name == "dictionary_open" ? nil : UnsafeMutableRawPointer(strdup(name))
        }

        let ffi = DictionaryFFI.load(openLibrary: openLibrary, symbol: symbol)

        #expect(ffi == nil)
    }

    @Test("returns nil when the prepare symbol is missing")
    func prepareSymbolMissing() {
        let openLibrary: (String) -> UnsafeMutableRawPointer? = { _ in
            UnsafeMutableRawPointer(bitPattern: 1)
        }
        let symbol: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer? = { _, name in
            // "dictionary_prepare" is the dylib's ABI literal, mirrored here.
            name == "dictionary_prepare" ? nil : UnsafeMutableRawPointer(strdup(name))
        }

        let ffi = DictionaryFFI.load(openLibrary: openLibrary, symbol: symbol)

        #expect(ffi == nil)
    }

    @Test("binds all symbols from the real runtime", .enabled(if: DictionaryFFI.load() != nil))
    func realRuntimeBindsAllSymbols() {}
}
