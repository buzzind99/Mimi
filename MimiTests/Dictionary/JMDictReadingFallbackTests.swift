import Foundation
@testable import Mimi
import SQLite3
import Testing

/// The annotator's reading fallback (`JMDictLookup.reading(forWriting:)`)
/// over the fixture database: the minimal kanji-writing → entry-reading
/// query behind the tokenizer's standalone-kanji gaps (圧, 灼, …).
@Suite("JMDictLookup reading fallback")
final class JMDictReadingFallbackTests {
    private let databaseURL: URL
    private let engine: JMDictLookup

    init() throws {
        let built = try JMDictFixtureDatabase.build()
        databaseURL = built.url
        engine = JMDictLookup(resolveDatabase: { [url = built.url] in url })
    }

    deinit {
        // Close before unlinking — SQLite warns loudly about vnodes removed
        // underneath an open handle.
        engine.close()
        JMDictFixtureDatabase.Built(url: databaseURL).remove()
    }

    @Test("reading returns the entry reading for a kanji writing")
    func readingForKanjiWriting() throws {
        let reading = try #require(try engine.reading(forWriting: "食べる"))

        #expect(reading == "たべる")
    }

    @Test("reading ranks the common entry first among kanji-writing homographs")
    func readingRanksCommonFirst() throws {
        // 前 heads two entries: the common 先/前 (さき) and the uncommon 前 (まえ).
        let reading = try #require(try engine.reading(forWriting: "前"))

        #expect(reading == "さき")
    }

    @Test("reading folds a katakana entry reading onto hiragana")
    func readingFoldsKatakanaReb() throws {
        let built = try makeKatakanaRebDatabase()
        let sut = JMDictLookup(resolveDatabase: { [url = built.url] in url })
        defer {
            sut.close()
            built.remove()
        }

        let reading = try #require(try sut.reading(forWriting: "魔語"))

        #expect(reading == "まご")
    }

    @Test("reading misses for a kana-only writing (keb headwords only)")
    func readingSkipsKanaOnlyWritings() throws {
        #expect(try engine.reading(forWriting: "アルバイト") == nil)
    }

    @Test("reading misses for an unknown writing")
    func readingMisses() throws {
        #expect(try engine.reading(forWriting: "誤語") == nil)
    }

    @Test("reading throws on a missing database")
    func readingThrowsOnMissingDatabase() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-jmdict-missing-\(UUID().uuidString).sqlite")
        let sut = JMDictLookup(resolveDatabase: { missing })

        #expect(throws: JMDictLookupError.self) {
            try sut.reading(forWriting: "食べる")
        }
    }

    /// Minimal database (the full fixture is unnecessary): a kanji-written
    /// entry whose entry reading is katakana, the shape the hiragana folding
    /// exists for (JMDict stores gairaigo entry readings in katakana).
    private func makeKatakanaRebDatabase() throws -> JMDictFixtureDatabase.Built {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-jmdict-katakana-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("jmdict-katakana.sqlite")

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            throw JMDictFixtureDatabase.FixtureError.sqlite("katakana fixture open failed")
        }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(
            db,
            """
            CREATE TABLE entries(ent_seq INTEGER PRIMARY KEY, keb TEXT, reb TEXT, common INTEGER NOT NULL);
            CREATE TABLE senses(entry_id INTEGER NOT NULL, ord INTEGER NOT NULL, pos TEXT,
              gloss TEXT NOT NULL, misc TEXT, skeb TEXT, sreb TEXT);
            CREATE TABLE headwords(entry_id INTEGER NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL,
              jlpt INTEGER, hatsuon TEXT, acc TEXT, zo TEXT);
            INSERT INTO entries VALUES (8880010, '魔語', 'マゴ', 0);
            INSERT INTO headwords VALUES (8880010, '魔語', 'keb', NULL, NULL, NULL, NULL);
            INSERT INTO headwords VALUES (8880010, 'マゴ', 'reb', NULL, NULL, NULL, NULL);
            """,
            nil, nil, nil
        ) == SQLITE_OK else {
            throw JMDictFixtureDatabase.FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return JMDictFixtureDatabase.Built(url: url)
    }
}
