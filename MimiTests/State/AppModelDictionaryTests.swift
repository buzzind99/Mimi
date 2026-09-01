import Foundation
@testable import Mimi
import Testing

/// Tests the first-launch dictionary kick-off wiring on `AppModel`: the
/// preparation starts only when no dictionary resolves, and a failed
/// preparation stays log-only (no user-visible error state). Both entry
/// points drive `prepareDictionaryIfNeeded` with fake closures — no real
/// store touched.
@MainActor
@Suite("AppModel dictionary preparation")
struct AppModelDictionaryTests {

    @Test("kicks dictionary preparation when no dictionary resolves")
    func kicksWhenUnresolved() {
        let model = AppModel()
        var prepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { nil },
            prepare: { _ in prepareCalls += 1 }
        )

        #expect(prepareCalls == 1)
    }

    @Test("skips dictionary preparation when a dictionary already resolves")
    func skipsWhenResolved() {
        let model = AppModel()
        let resolved = URL(fileURLWithPath: "/tmp/ipadic.dic")
        var prepareCalls = 0

        model.prepareDictionaryIfNeeded(
            resolve: { resolved },
            prepare: { _ in prepareCalls += 1 }
        )

        #expect(prepareCalls == 0)
    }

    @Test("a failed preparation is log-only and raises no user-visible error")
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

    @Test("session-start gate skips preparation when a dictionary already resolves")
    func gateSkipsWhenResolved() async throws {
        let model = AppModel()
        let resolved = URL(fileURLWithPath: "/tmp/ipadic.dic")
        var prepareCalls = 0

        try await model.ensureDictionaryReady(
            resolve: { resolved },
            prepare: { _ in prepareCalls += 1 }
        )

        #expect(prepareCalls == 0)
        #expect(!model.isPreparingDictionary)
    }

    @Test("session-start gate prepares when no dictionary resolves and clears the flag")
    func gatePreparesWhenUnresolved() async throws {
        let model = AppModel()
        var prepareCalls = 0
        var preparingDuringPreparation = false

        try await model.ensureDictionaryReady(
            resolve: { nil },
            prepare: { completion in
                prepareCalls += 1
                preparingDuringPreparation = model.isPreparingDictionary
                completion(.success(URL(fileURLWithPath: "/tmp/ipadic.dic")))
            }
        )

        #expect(prepareCalls == 1)
        #expect(preparingDuringPreparation)
        #expect(!model.isPreparingDictionary)
    }

    @Test("session-start gate rethrows a failed preparation so the start fails visibly")
    func gateRethrowsFailedPreparation() async throws {
        let model = AppModel()
        let failure = DictionaryStore.DictionaryStoreError.prepareFailed(returnCode: 1)

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
