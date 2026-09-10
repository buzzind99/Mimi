import Foundation
@testable import Mimi
import SQLite3
import Testing

@Suite("SQLiteDatabase")
final class SQLiteDatabaseTests {

    private let tempRoot: URL
    /// Probe database with two rows in a `t(id, label, score)` table: one
    /// fully populated, one with NULLs in every optional column, so the
    /// statement accessors are pinned against both shapes.
    private let databaseURL: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-sqlitedatabase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        databaseURL = tempRoot.appendingPathComponent("probe.sqlite")
        try Self.createDatabase(at: databaseURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Open

    @Test("opening a database in a missing directory throws a SQLite error")
    func openFailsForMissingDirectory() {
        let missing = tempRoot.appendingPathComponent("no-such-dir/probe.sqlite")

        let error = #expect(throws: SQLiteDatabase.Error.self) {
            try SQLiteDatabase(path: missing.path)
        }

        guard case let .sqlite(_, message)? = error else {
            Issue.record("expected .sqlite, got \(String(describing: error))")
            return
        }
        #expect(!message.isEmpty)
    }

    // MARK: - Statement cache

    @Test("a cached statement is reusable and resets between uses")
    func statementReuseResets() throws {
        let db = try SQLiteDatabase(path: databaseURL.path)
        let sql = "SELECT id FROM t ORDER BY id"

        var ids: [Int] = []
        let first = try db.statement(sql)
        while try first.step() {
            ids.append(first.requiredInt(0))
        }
        #expect(ids == [1, 2])

        var reused: [Int] = []
        let second = try db.statement(sql)
        while try second.step() {
            reused.append(second.requiredInt(0))
        }
        #expect(reused == [1, 2])
    }

    @Test("a statement left mid-loop is reset before its next use")
    func partialConsumptionResets() throws {
        let db = try SQLiteDatabase(path: databaseURL.path)
        let sql = "SELECT id FROM t ORDER BY id"

        let partial = try db.statement(sql)
        #expect(try partial.step())

        var ids: [Int] = []
        let fresh = try db.statement(sql)
        while try fresh.step() {
            ids.append(fresh.requiredInt(0))
        }
        #expect(ids == [1, 2])
    }

    @Test("compiling invalid SQL throws a SQLite error")
    func badSQLThrows() throws {
        let db = try SQLiteDatabase(path: databaseURL.path)

        #expect(throws: SQLiteDatabase.Error.self) {
            try db.statement("SELECT nope FROM t")
        }
    }

    @Test("stepping a statement whose table disappeared throws a SQLite error")
    func stepThrowsAfterSchemaChange() throws {
        let db = try SQLiteDatabase(path: databaseURL.path)
        let statement = try db.statement("SELECT id FROM t")

        var raw: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path, &raw, SQLITE_OPEN_READWRITE, nil
        ) == SQLITE_OK, let raw else {
            Issue.record("raw fixture connection failed to open")
            return
        }
        defer { sqlite3_close_v2(raw) }
        try Self.exec(raw, "DROP TABLE t")

        #expect(throws: SQLiteDatabase.Error.self) {
            try statement.step()
        }
    }

    // MARK: - Bindings and columns

    @Test("bindings parameterize string and integer queries")
    func bindings() throws {
        let db = try SQLiteDatabase(path: databaseURL.path)

        let byLabel = try db.statement("SELECT id FROM t WHERE label = ?")
        byLabel.bind("alpha", at: 1)
        #expect(try byLabel.step())
        #expect(byLabel.requiredInt(0) == 1)
        #expect(try !byLabel.step())

        let byScore = try db.statement("SELECT id FROM t WHERE score = ?")
        byScore.bind(7, at: 1)
        #expect(try byScore.step())
        #expect(byScore.requiredInt(0) == 1)
    }

    @Test("column accessors map populated and NULL columns correctly")
    func columnAccessors() throws {
        let db = try SQLiteDatabase(path: databaseURL.path)
        let statement = try db.statement("SELECT id, label, score FROM t ORDER BY id")

        #expect(try statement.step())
        #expect(statement.requiredInt(0) == 1)
        #expect(statement.optionalText(1) == "alpha")
        #expect(statement.optionalInt(2) == 7)
        #expect(statement.bool(2))

        #expect(try statement.step())
        #expect(statement.requiredInt(0) == 2)
        #expect(statement.optionalText(1) == nil)
        #expect(statement.optionalInt(2) == nil)
        #expect(!statement.bool(2))

        #expect(try !statement.step())
    }

    // MARK: - Close

    @Test("close is idempotent and statements after close throw")
    func closeSemantics() throws {
        let db = try SQLiteDatabase(path: databaseURL.path)
        _ = try db.statement("SELECT id FROM t")

        db.close()
        db.close()

        #expect(throws: SQLiteDatabase.Error.self) {
            try db.statement("SELECT id FROM t")
        }
    }

    // MARK: - Helpers

    private static func createDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let db else {
            Issue.record("probe database failed to open")
            return
        }
        defer { sqlite3_close_v2(db) }
        try exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, label TEXT, score INTEGER)")
        try exec(db, "INSERT INTO t(id, label, score) VALUES (1, 'alpha', 7)")
        try exec(db, "INSERT INTO t(id, label, score) VALUES (2, NULL, NULL)")
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private enum FixtureError: Error {
        case sqlite(String)
    }
}
