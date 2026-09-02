import Foundation
@testable import Mimi

/// In-memory `SecureKeyStoring` for tests — no Keychain, no shared OS state,
/// safe under Swift Testing's parallel execution. Guarded by a lock because
/// the protocol is `Sendable`.
final class InMemoryKeyStore: SecureKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func saveKey(_ key: String, for providerID: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[providerID] = key
    }

    func readKey(for providerID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[providerID]
    }

    func deleteKey(for providerID: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: providerID)
    }
}
