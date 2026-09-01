import Foundation
@testable import Mimi
import Testing

/// Tests the first-launch dictionary kick-off wiring on `AppModel`: the
/// build starts only when no database resolves, and a failed build stays
/// log-only (no user-visible error state). Both entry points drive
/// `prepareDictionaryIfNeeded` with fake closures — no real store touched.
@MainActor
@Suite("AppModel dictionary preparation")
struct AppModelDictionaryTests {

    @Test("kicks the dictionary build when no database resolves")
    func kicksWhenUnresolved() {
        let model = AppModel()
        var prepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { nil },
            prepare: { _ in prepareCalls += 1 }
        )

        #expect(prepareCalls == 1)
    }

    @Test("skips the dictionary build when a database already resolves")
    func skipsWhenResolved() {
        let model = AppModel()
        let resolved = URL(fileURLWithPath: "/tmp/jmdict.db")
        var prepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { resolved },
            prepare: { _ in prepareCalls += 1 }
        )

        #expect(prepareCalls == 0)
    }

    @Test("a failed build is log-only and raises no user-visible error")
    func failedBuildStaysQuiet() {
        let model = AppModel()
        var completion: ((Result<URL, Error>) -> Void)?
        let failure = DictionaryStore.DictionaryStoreError.libraryUnavailable

        model.prepareDictionaryIfNeeded(
            resolve: { nil },
            prepare: { completion = $0 }
        )
        completion?(.failure(failure))

        #expect(model.errorMessage == nil)
    }

    // MARK: - Session-start gate (`ensureDictionaryReady`)

    @Test("session-start gate skips the build when a database already resolves")
    func gateSkipsWhenResolved() async throws {
        let model = AppModel()
        let resolved = URL(fileURLWithPath: "/tmp/jmdict.db")
        var prepareCalls = 0

        try await model.ensureDictionaryReady(
            resolve: { resolved },
            prepare: { _ in prepareCalls += 1 }
        )

        #expect(prepareCalls == 0)
        #expect(!model.isPreparingDictionary)
    }

    @Test("session-start gate builds when no database resolves and clears the flag")
    func gateBuildsWhenUnresolved() async throws {
        let model = AppModel()
        var prepareCalls = 0
        var preparingDuringBuild = false

        try await model.ensureDictionaryReady(
            resolve: { nil },
            prepare: { completion in
                prepareCalls += 1
                preparingDuringBuild = model.isPreparingDictionary
                completion(.success(URL(fileURLWithPath: "/tmp/jmdict.db")))
            }
        )

        #expect(prepareCalls == 1)
        #expect(preparingDuringBuild)
        #expect(!model.isPreparingDictionary)
    }

    @Test("session-start gate rethrows a failed build so the start fails visibly")
    func gateRethrowsFailedBuild() async throws {
        let model = AppModel()
        let failure = DictionaryStore.DictionaryStoreError.buildFailed(returnCode: 1)

        await #expect(throws: (any Error).self) {
            try await model.ensureDictionaryReady(
                resolve: { nil },
                prepare: { completion in completion(.failure(failure)) }
            )
        }

        #expect(!model.isPreparingDictionary)
        #expect(model.errorMessage == nil)
    }
}
