import Foundation
@testable import Mimi
import Testing

// MARK: - DylibLoader.open

@Suite("DylibLoader opening")
struct DylibLoaderOpenTests {

    @Test("a real dlopen failure surfaces dlerror's message")
    func missingPathSurfacesLastError() {
        let result = DylibLoader.open(candidates: ["/nonexistent/mimi-no-such.dylib"])

        #expect(result.handle == nil)
        #expect(result.lastError != nil)
    }

    @Test("dlopen of a non-library file fails cleanly with an error message")
    func nonLibraryFileSurfacesLastError() throws {
        let scratch = try TemporaryDirectory(prefix: "mimi-dylibloader")
        let fileURL = try scratch.write(Data("not a mach-o file".utf8), named: "not-a-library.dylib")

        let result = DylibLoader.open(candidates: [fileURL.path])

        #expect(result.handle == nil)
        #expect(result.lastError != nil)
    }

    @Test("open skips nil candidates and stops at the first success")
    func skipsNilCandidatesStopsAtFirstSuccess() {
        var opened: [String] = []
        let opener: (String) -> UnsafeMutableRawPointer? = { path in
            opened.append(path)
            return path == "b" ? UnsafeMutableRawPointer(bitPattern: 2) : nil
        }

        let result = DylibLoader.open(candidates: [nil, nil, "a", "b", "c"], open: opener)

        #expect(result.handle == UnsafeMutableRawPointer(bitPattern: 2))
        #expect(opened == ["a", "b"])
    }

    @Test("open reports nil lastError when the opener is injected")
    func injectedOpenerYieldsNilLastError() {
        let opener: (String) -> UnsafeMutableRawPointer? = { _ in nil }

        let result = DylibLoader.open(candidates: ["a", "b"], open: opener)

        #expect(result.handle == nil)
        #expect(result.lastError == nil)
    }
}

// MARK: - DylibLoader.candidates

#if DEBUG
    @Suite("DylibLoader candidates")
    struct DylibLoaderCandidatesTests {

        @Test("puts the bare name first and the debug checkout fallback last")
        func bareNameFirstFallbackLast() {
            let fallback = FileManager.default.currentDirectoryPath
                + "/local/frameworks/crispasr/libdictionary.dylib"

            let candidates = DylibLoader.candidates(
                named: "libdictionary.dylib",
                debugFallbackSubdirectory: "crispasr"
            )

            let nonNil = candidates.compactMap(\.self)
            #expect(nonNil.first == "libdictionary.dylib")
            #expect(nonNil.last == fallback)
            for middle in nonNil.dropFirst().dropLast() {
                #expect(middle.hasSuffix("/libdictionary.dylib"))
            }
        }

        @Test("an unset debug env key contributes a nil slot that open skips")
        func unsetEnvKeyContributesNilSlot() {
            let key = "MIMI_TEST_DYLIBLOADER_UNSET_ENV"
            #expect(ProcessInfo.processInfo.environment[key] == nil)

            let candidates = DylibLoader.candidates(named: "libdictionary.dylib", debugEnvKey: key)

            #expect(candidates[0] == nil)
        }
    }

    @Suite("DylibLoader env override", .serialized)
    struct DylibLoaderEnvOverrideTests {

        private static let envKey = "MIMI_TEST_DYLIBLOADER_ENV_OVERRIDE"

        @Test("a set debug env key contributes its path as the first candidate")
        func setEnvKeyBecomesFirstCandidate() throws {
            setenv(Self.envKey, "/tmp/mimi-override.dylib", 1)
            defer { unsetenv(Self.envKey) }

            let candidates = DylibLoader.candidates(
                named: "libdictionary.dylib",
                debugEnvKey: Self.envKey
            )

            let first = try #require(candidates.first)
            #expect(first == "/tmp/mimi-override.dylib")
            #expect(candidates.dropFirst().contains("libdictionary.dylib"))
        }
    }
#endif
