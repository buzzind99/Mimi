import Foundation

/// Lookup infrastructure failures. Deliberately typed throws (not the
/// tokenizer's fail-soft nil): the UI must distinguish a genuine no-hit
/// (nil → warning pill) from a broken database (throw → error toast).
enum JMDictLookupError: LocalizedError, Equatable {
    case databaseMissing
    case databaseClosed
    case sqliteError(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .databaseMissing:
            "JMDict database not found; the dictionary may still be preparing."
        case .databaseClosed:
            "JMDict database has been closed."
        case let .sqliteError(code, message):
            "JMDict database error \(code): \(message)."
        }
    }
}
