import Foundation
@testable import Mimi
import Testing

// MARK: - DictionaryStore: second artifact (JMDict)

//
// JMDict-side tests for `DictionaryStore`: versioned resolve/staging, the
// lookup-engine smoke query, and stale-artifact cleanup. Declared as an
// extension of `DictionaryStoreTests` so both artifact halves run inside the
// same serialized suite — the fake FFI state they share is file-scope mutable
// (see DictionaryStoreTests.swift).

extension DictionaryStoreTests {

    // MARK: errorDescription

    @Test("names the missing bundled JMDict artifact")
    func bundledJMDictMissingMessage() {
        let error = DictionaryStore.DictionaryStoreError.bundledJMDictMissing

        #expect(
            error.errorDescription
                == "Bundled \(JMDictPin.bundledFileName) not found in the app bundle."
        )
    }

    // MARK: resolveJMDict

    #if DEBUG
        @Test("resolves the MIMI_JMDICT override set on the process")
        func jmDictProcessEnvOverride() throws {
            let overrideURL = tempRoot.appendingPathComponent("override-jmdict.sqlite")
            try Data("sqlite".utf8).write(to: overrideURL)
            dictionaryEnvLock.lock()
            defer { dictionaryEnvLock.unlock() }
            setenv("MIMI_JMDICT", overrideURL.path, 1)
            defer { unsetenv("MIMI_JMDICT") }

            let resolved = DictionaryStore.resolveJMDict()

            #expect(resolved?.path == overrideURL.path)
        }
    #endif

    @Test("returns the default versioned location when it exists")
    func resolvesJMDictDefaultLocation() {
        let defaultExists: (URL) -> Bool = { $0.pathComponents.contains("dictionaries") }

        let url = DictionaryStore.resolveJMDict(environment: [:], fileExists: defaultExists)

        #expect(url == DictionaryStore.defaultJMDictURL)
    }

    @Test("prefers an existing MIMI_JMDICT override")
    func jmDictEnvOverrideWins() {
        let overridePath = "/custom/jmdict.sqlite"
        let overrideExists: (URL) -> Bool = { $0.path == overridePath }

        let url = DictionaryStore.resolveJMDict(
            environment: ["MIMI_JMDICT": overridePath], fileExists: overrideExists
        )

        #expect(url?.path == overridePath)
    }

    @Test("falls through to the default location when the MIMI_JMDICT override is missing")
    func jmDictMissingEnvOverrideFallsThrough() {
        let missingOverride = "/missing/jmdict.sqlite"
        let defaultExists: (URL) -> Bool = { $0.pathComponents.contains("dictionaries") }

        let url = DictionaryStore.resolveJMDict(
            environment: ["MIMI_JMDICT": missingOverride], fileExists: defaultExists
        )

        #expect(url == DictionaryStore.defaultJMDictURL)
    }

    @Test("returns nil when no JMDict candidate exists")
    func jmDictNothingResolves() {
        let nothingExists: (URL) -> Bool = { _ in false }

        let url = DictionaryStore.resolveJMDict(environment: [:], fileExists: nothingExists)

        #expect(url == nil)
    }

    // MARK: default locations

    @Test("composes the versioned JMDict destination path from the pin")
    func defaultJMDictPath() {
        let path = DictionaryStore.defaultJMDictURL.path

        #expect(path.hasSuffix("Mimi/dictionaries/\(JMDictPin.preparedFileName)"))
    }

    // MARK: prepareJMDict (fake runtime)

    @Test("decompresses the JMDict artifact into the versioned destination on first launch")
    func jmDictFirstPrepareMovesIntoPlace() async throws {
        fakePrepareCopySource = smokeDatabase
        let store = makeStore()

        let url = try await store.prepareJMDict()

        #expect(url == destination.appendingPathComponent(JMDictPin.preparedFileName))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("adopts a JMDict database prepared by an earlier launch without decompressing")
    func jmDictAdoptsExistingDestination() async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent(JMDictPin.preparedFileName)
        try Data(previousDicContents.utf8).write(to: existing)
        let store = makeStore()

        let url = try await store.prepareJMDict()

        #expect(url == existing)
        #expect(fakePrepareCalls == 0, "an existing database must short-circuit the decompress")
    }

    @Test("is a no-op once the JMDict database is prepared")
    func jmDictSecondPrepareIsNoOp() async throws {
        fakePrepareCopySource = smokeDatabase
        let store = makeStore()
        let prepared = try await store.prepareJMDict()

        let second = try await store.prepareJMDict()

        #expect(second == prepared, "a successful prepare must never re-decompress")
        #expect(fakePrepareCalls == 1)
    }

    @Test("coalesces concurrent JMDict callers into one decompression")
    func jmDictConcurrentCallersCoalesce() async throws {
        fakePrepareCopySource = smokeDatabase
        fakePrepareDelayMs = 300
        let store = makeStore()

        async let first = store.prepareJMDict()
        async let second = store.prepareJMDict()
        async let third = store.prepareJMDict()
        let results = try await(first, second, third)

        #expect(results.0 == results.1 && results.1 == results.2)
        #expect(fakePrepareCalls == 1, "all callers must share the single decompression")
    }

    @Test("removes stale versioned JMDict artifacts after a successful promote")
    func jmDictPromoteRemovesLegacyArtifacts() async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stale = destination.appendingPathComponent("jmdict-0.9.9-auto-release-old.sqlite")
        try Data("stale pin".utf8).write(to: stale)
        fakePrepareCopySource = smokeDatabase
        let store = makeStore()

        let url = try await store.prepareJMDict()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("reports a JMDict decompression failure and leaves no partial database")
    func jmDictPrepareFailureLeavesNoPartialFile() async throws {
        let store = makeStore(ffi: makeFakeFFI(prepare: fakePrepareFail))

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        #expect(error == .prepareFailed(returnCode: 1))
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(JMDictPin.preparedFileName).path
            ),
            "a failed prepare must not leave a partial database"
        )
    }

    @Test("re-attempts the JMDict decompression on the next call after a failure")
    func jmDictFailedPrepareRetries() async throws {
        let store = makeStore(ffi: makeFakeFFI(prepare: fakePrepareFail))
        _ = try? await store.prepareJMDict()

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        #expect(error == .prepareFailed(returnCode: 1))
        #expect(fakePrepareCalls == 2, "the retry must re-attempt the decompression")
    }

    @Test("fails the JMDict smoke query when the artifact is not a database")
    func jmDictSmokeRejectsNonDatabase() async throws {
        // The default fake prepare writes the plain placeholder payload —
        // not SQLite — so the JMDict lookup over the staged file must throw.
        let store = makeStore()

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        guard case let .smokeTestFailed(reason) = error else {
            Issue.record("expected .smokeTestFailed, got \(error)")
            return
        }
        #expect(reason.contains("JMDict database error"))
    }

    @Test("fails the JMDict smoke query when the smoke word has no entry")
    func jmDictSmokeRejectsEntryLessDatabase() async throws {
        let entryLess = try makeJMDictSmokeDatabase(includeSmokeWord: false)
        defer { try? FileManager.default.removeItem(at: entryLess.deletingLastPathComponent()) }
        fakePrepareCopySource = entryLess
        let store = makeStore()

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        #expect(error == .smokeTestFailed(reason: "no entry for 学生"))
    }

    @Test("fails when the bundled JMDict artifact is missing")
    func jmDictBundledSourceMissing() async throws {
        let store = DictionaryStore(
            bundledSource: fixtureZst, bundledJMDictSource: nil,
            destinationDirectory: destination, ffi: makeFakeFFI()
        )

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        #expect(error == .bundledJMDictMissing)
        #expect(fakePrepareCalls == 0)
    }

    // MARK: prepareJMDict (live runtime)

    @Test("decompresses the real built JMDict artifact on first launch")
    func jmDictLiveFirstLaunchDecompresses() async throws {
        guard let ffi = DictionaryFFI.load() else {
            try Test.cancel("libdictionary.dylib is not available")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let artifact = root.appendingPathComponent("local/dictionaries/\(JMDictPin.bundledFileName)")
        guard FileManager.default.fileExists(atPath: artifact.path) else {
            try Test.cancel("the built JMDict artifact is not available")
        }
        let store = DictionaryStore(
            bundledSource: nil, bundledJMDictSource: artifact,
            destinationDirectory: destination, ffi: ffi
        )

        let url = try await store.prepareJMDict()

        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
