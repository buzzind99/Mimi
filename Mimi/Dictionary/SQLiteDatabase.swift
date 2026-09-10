import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` — SQLite's destructor constant is not exposed to Swift
/// directly; -1 instructs SQLite to copy the bound string immediately.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A SQLite connection owning a prepared-statement cache — the only type in
/// the app that imports SQLite3. Engines drive it through `statement(_:)`
/// and the row accessors on `Statement`, so the raw C handle never escapes.
///
/// Thread-safety is the caller's concern: `JMDictLookup` serializes access
/// under its own lock, matching the single-handle lifetime it manages.
final class SQLiteDatabase {
    enum Error: Swift.Error, Equatable {
        /// No handle could be created (an unopenable path).
        case unavailable
        /// SQLite reported an error code and message.
        case sqlite(code: Int32, message: String)
    }

    /// A prepared statement in a database's cache. Borrowed for one statement
    /// at a time; a repeat request resets the prior step and bindings.
    final class Statement {
        private let handle: OpaquePointer
        private let database: OpaquePointer

        fileprivate init(_ handle: OpaquePointer, database: OpaquePointer) {
            self.handle = handle
            self.database = database
        }

        /// Binds a string at the 1-based parameter `index`.
        func bind(_ value: String, at index: Int32) {
            sqlite3_bind_text(handle, index, value, -1, sqliteTransient)
        }

        /// Binds an integer at the 1-based parameter `index`.
        func bind(_ value: Int, at index: Int32) {
            sqlite3_bind_int64(handle, index, Int64(value))
        }

        /// Advances the statement: true on a row, false once done.
        func step() throws(Error) -> Bool {
            switch sqlite3_step(handle) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteDatabase.error(database)
            }
        }

        /// The 0-based column as text, or nil when NULL.
        func optionalText(_ index: Int32) -> String? {
            guard let cString = sqlite3_column_text(handle, index) else { return nil }
            return String(cString: cString)
        }

        /// The 0-based column as an integer, or nil when NULL.
        func optionalInt(_ index: Int32) -> Int? {
            guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(handle, index))
        }

        /// The 0-based column as a non-optional integer (a NOT NULL column).
        func requiredInt(_ index: Int32) -> Int {
            Int(sqlite3_column_int64(handle, index))
        }

        /// The 0-based column as a Bool (nonzero = true).
        func bool(_ index: Int32) -> Bool {
            sqlite3_column_int(handle, index) != 0
        }
    }

    private let handle: OpaquePointer
    private var preparedStatements: [String: OpaquePointer] = [:]
    private var isClosed = false

    init(path: String) throws(Error) {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let opened
        else {
            let failure: Error = opened.map(Self.error) ?? .unavailable
            sqlite3_close_v2(opened)
            throw failure
        }
        handle = opened
    }

    deinit {
        close()
    }

    /// Returns the cached statement for `sql`, resetting any prior step and
    /// bindings; compiles it on first use (`sqlite3_prepare_v2` dominates a
    /// repeat query's cost). Callers fully consume each statement before
    /// returning, so reuse is safe.
    func statement(_ sql: String) throws(Error) -> Statement {
        if let cached = preparedStatements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return Statement(cached, database: handle)
        }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK,
              let prepared
        else {
            throw Self.error(handle)
        }
        preparedStatements[sql] = prepared
        return Statement(prepared, database: handle)
    }

    /// The connection's current error code and message.
    func lastError() -> Error {
        Self.error(handle)
    }

    /// Finalizes every cached statement and closes the handle. Idempotent, so
    /// an explicit close followed by deinit is safe.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        for statement in preparedStatements.values {
            sqlite3_finalize(statement)
        }
        preparedStatements.removeAll()
        sqlite3_close_v2(handle)
    }

    private static func error(_ db: OpaquePointer) -> Error {
        .sqlite(
            code: sqlite3_errcode(db),
            message: String(cString: sqlite3_errmsg(db))
        )
    }
}
