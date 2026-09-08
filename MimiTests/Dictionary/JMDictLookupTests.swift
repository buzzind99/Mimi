import Foundation
@testable import Mimi
import SQLite3
import Testing

@Suite("JMDictLookup")
final class JMDictLookupTests {
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

    // MARK: Hits

    @Test("hits the lemma candidate with pitch and JLPT from the matched headword row")
    func lemmaHit() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "食べる")))

        #expect(result.matched == "食べる")
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 1_358_280)
        #expect(entry.keb == "食べる")
        #expect(entry.reb == "たべる")
        #expect(entry.common)
        #expect(entry.jlpt == 5)
        #expect(entry.hatsuon == "た~べる")
        #expect(entry.accPatts == "2")
        #expect(entry.zoPatts == "LHLL")
        #expect(entry.senses.count == 2)
        #expect(entry.senses[0].pos == "v1,vt")
        #expect(entry.senses[0].glosses == ["to eat"])
        #expect(entry.senses[1].glosses == ["to live on (e.g. a salary)", "to live off", "to subsist on"])
    }

    @Test("hits the kana-only gairaigo entry with commonness from the kana object")
    func kanaOnlyHit() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "アルバイト")))

        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 1_019_420)
        #expect(entry.keb == nil)
        #expect(entry.reb == "アルバイト")
        #expect(entry.common)
        #expect(entry.jlpt == 4)
        #expect(entry.hatsuon == "あるばいと")
        #expect(entry.accPatts == "3")
        #expect(entry.zoPatts == "LHHLLL")
        #expect(entry.senses[0].pos == "n,vs,vi")
        #expect(entry.senses[0].glosses == ["part-time job", "side job"])
    }

    @Test("orders senses by ord and splits the stored joins back apart")
    func multiSenseOrder() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あめ")))

        let entry = try #require(result.entries.first { $0.entSeq == 1_153_520 })
        #expect(entry.senses.map { $0.glosses.first } == ["(hard) candy", "rice-sugar", "amber"])
        #expect(entry.senses[2].misc == "abbr")
        #expect(entry.senses[1].pos == "n")
    }

    // MARK: Restriction filtering

    @Test("drops kanji-restricted senses: foreign restriction, empty list; keeps unrestricted")
    func kanjiRestrictionFiltering() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "仮語")))

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 9_990_010)
        #expect(entry.senses.count == 1)
        #expect(entry.senses[0].glosses == ["applies to every writing"])
    }

    @Test("drops the kana-restricted sense for a reading outside the restriction")
    func kanaRestrictedSenseDropped() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あしこ")))

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 1_000_320)
        #expect(entry.senses.count == 2)
        #expect(entry.senses.map { $0.glosses.first } == ["there", "that far"])
    }

    @Test("keeps the kana-restricted sense for a reading inside the restriction")
    func kanaRestrictedSenseKept() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あそこ")))

        let entry = try #require(result.entries.first)
        #expect(entry.senses.count == 3)
    }

    @Test("drops an entry whose every sense is filtered away for the candidate")
    func fullyFilteredEntryDropped() throws {
        #expect(try engine.lookup(LookupCandidate(text: "幽語")) == nil)
    }

    // MARK: Headword-row sourcing

    @Test("takes jlpt and pitch verbatim from the matched kana headword row")
    func jlptFromMatchedRow() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "ふろしき")))

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 1_500_150)
        #expect(entry.jlpt == nil, "the kana row's null wins over the kanji row's 2")
        #expect(entry.hatsuon == "ふろ'[Dev]しき")
        #expect(entry.zoPatts == "LHHHH")
    }

    @Test("leaves pitch nil when the matched headword row has none")
    func pitchNullWhenRowLacksIt() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "お土産")))

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 1_002_500)
        #expect(entry.jlpt == 4)
        #expect(entry.hatsuon == nil)
        #expect(entry.accPatts == nil)
        #expect(entry.zoPatts == nil)
    }

    // MARK: Homographs

    @Test("returns all homograph entries ranked common-first then ent_seq")
    func homographRanking() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あめ")))

        #expect(result.entries.map(\.entSeq) == [1_153_520, 9_990_030])
        #expect(result.entries.map(\.common) == [true, false])
    }

    // MARK: Reading-match ranking

    @Test("ranks the furigana-matching entry first across the shared headword")
    func readingMatchRanksFirst() throws {
        // 先 (saki, uncommon 前 as an alternate writing) and 前 (mae) both
        // match the 前 headword; the tap's furigana names the reading in
        // context, so the uncommon まえ entry outranks the common さき one.
        let result = try #require(try engine.lookup(
            LookupCandidate(text: "前", reading: "まえ")
        ))

        #expect(result.entries.map(\.entSeq) == [9_990_060, 9_990_050])
        #expect(result.entries.map(\.reb) == ["まえ", "さき"])
    }

    @Test("katakana furigana matches the hiragana entry reading")
    func katakanaFuriganaMatchesHiraganaReading() throws {
        let result = try #require(try engine.lookup(
            LookupCandidate(text: "前", reading: "マエ")
        ))

        #expect(result.entries.map(\.entSeq) == [9_990_060, 9_990_050])
    }

    @Test("without a reading the homographs keep the common-first ent_seq order")
    func noReadingKeepsPriorOrder() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "前")))

        #expect(result.entries.map(\.entSeq) == [9_990_050, 9_990_060])
        #expect(result.entries.map(\.common) == [true, false])
    }

    // MARK: Misses

    @Test("returns nil for a candidate with no headword")
    func noHitReturnsNil() throws {
        #expect(try engine.lookup(LookupCandidate(text: "きのこっぷ")) == nil)
    }

    @Test("returns nil for an empty candidate list")
    func emptyCandidateListReturnsNil() throws {
        #expect(try engine.lookup([]) == nil)
    }

    // MARK: Candidate ordering

    @Test("first hit wins for display; later hits adding entries are kept as also")
    func orderedCandidates() throws {
        let outcome = try #require(try engine.lookup([
            LookupCandidate(text: "飴"),
            LookupCandidate(text: "あめ")
        ]))

        #expect(outcome.display.matched == "飴")
        #expect(outcome.display.entries.map(\.entSeq) == [1_153_520])
        #expect(outcome.also.map(\.matched) == ["あめ"])
        #expect(outcome.also[0].entries.map(\.entSeq) == [1_153_520, 9_990_030])
    }

    @Test("skips a later candidate that only re-hits already-returned entries")
    func duplicateEntryCandidateSkipped() throws {
        let outcome = try #require(try engine.lookup([
            LookupCandidate(text: "食べる"),
            LookupCandidate(text: "たべる")
        ]))

        #expect(outcome.display.matched == "食べる")
        #expect(outcome.also.isEmpty)
    }

    @Test("keeps candidate order across several also results")
    func alsoOrderFollowsCandidates() throws {
        let outcome = try #require(try engine.lookup([
            LookupCandidate(text: "橋"),
            LookupCandidate(text: "たべる"),
            LookupCandidate(text: "アルバイト")
        ]))

        #expect(outcome.display.matched == "橋")
        #expect(outcome.also.map(\.matched) == ["たべる", "アルバイト"])
    }

    // MARK: Candidate kind

    @Test("derives the candidate kind from the script", arguments: [
        ("食べる", LookupCandidate.Kind.kanji),
        ("たべる", LookupCandidate.Kind.kana),
        ("アルバイト", LookupCandidate.Kind.kana),
        ("𠮷野家", LookupCandidate.Kind.kanji),
        ("A", LookupCandidate.Kind.kana)
    ])
    func kindDerivation(text: String, kind: LookupCandidate.Kind) {
        #expect(LookupCandidate(text: text).kind == kind)
    }

    // MARK: Infrastructure errors

    @Test("throws databaseMissing when no database resolves")
    func missingDatabaseThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-jmdict-missing-\(UUID().uuidString).sqlite")
        let sut = JMDictLookup(resolveDatabase: { missing })

        let thrown = #expect(throws: JMDictLookupError.self) {
            try sut.lookup(LookupCandidate(text: "食べる"))
        }

        #expect(thrown == .databaseMissing)
    }

    @Test("throws databaseClosed after close()")
    func closedHandleThrows() throws {
        _ = try engine.lookup(LookupCandidate(text: "食べる"))
        engine.close()

        let thrown = #expect(throws: JMDictLookupError.self) {
            try engine.lookup(LookupCandidate(text: "食べる"))
        }

        #expect(thrown == .databaseClosed)
    }

    @Test("throws a sqlite error for a corrupt database file")
    func corruptDatabaseThrows() throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-jmdict-corrupt-\(UUID().uuidString).sqlite")
        try Data("definitely not a sqlite database".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        let sut = JMDictLookup(resolveDatabase: { corrupt })

        let thrown = try #require(
            #expect(throws: JMDictLookupError.self) {
                try sut.lookup(LookupCandidate(text: "食べる"))
            }
        )

        guard case .sqliteError = thrown else {
            Issue.record("expected .sqliteError, got \(thrown)")
            return
        }
    }

    @Test("error descriptions are actionable copy per case")
    func errorDescriptions() {
        #expect(
            JMDictLookupError.databaseMissing.errorDescription
                == "JMDict database not found; the dictionary may still be preparing."
        )
        #expect(
            JMDictLookupError.databaseClosed.errorDescription
                == "JMDict database has been closed."
        )
        #expect(
            JMDictLookupError.sqliteError(code: 11, message: "corrupt").errorDescription
                == "JMDict database error 11: corrupt."
        )
    }

    @Test("default database resolution prefers the prepared location, then the debug checkout")
    func defaultDatabaseResolution() {
        let destination = URL(fileURLWithPath: "/tmp/dest")
        let prepared = destination.appendingPathComponent(JMDictPin.preparedFileName)

        // The prepared location wins whenever it exists.
        #expect(
            JMDictLookup.defaultDatabaseURL(destination: destination, fileExists: { _ in true })
                == prepared
        )

        // Without it, the debug checkout (build/<tag>.sqlite) resolves.
        let checkout = URL(fileURLWithPath: "build/\(JMDictPin.preparedFileName)")
        #expect(
            JMDictLookup.defaultDatabaseURL(
                destination: destination,
                fileExists: { $0 == checkout }
            ) == checkout
        )

        // Neither resolves → nil (lookups then throw .databaseMissing).
        #expect(
            JMDictLookup.defaultDatabaseURL(destination: destination, fileExists: { _ in false }) == nil
        )
    }

    /// A path SQLite cannot open at all (a directory) fails `sqlite3_open_v2`
    /// itself — the never-cached failure branch. Each act is one lookup; two
    /// sequential acts assert the second call retries (and fails again):
    /// failed opens must not latch the engine closed.
    @Test("an unopenable database path throws and stays retryable")
    func unopenableDatabasePathThrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-jmdict-unopenable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sut = JMDictLookup(resolveDatabase: { directory })

        let firstThrown = try thrownForOneLookup(sut)
        let retryThrown = try thrownForOneLookup(sut)

        #expect(retryThrown == firstThrown, "the failure must repeat on retry")
    }

    /// One lookup against `sut`. SQLite surfaces an unopenable path as
    /// either the typed missing case or a CANTOPEN sqlite error, depending
    /// on whether it handed back a handle — both are accepted here.
    private func thrownForOneLookup(_ sut: JMDictLookup) throws -> JMDictLookupError {
        let thrown = try #require(
            #expect(throws: JMDictLookupError.self) {
                try sut.lookup(LookupCandidate(text: "食べる"))
            }
        )
        #expect(
            thrown == .databaseMissing || isSQLiteError(thrown),
            "expected .databaseMissing or .sqliteError, got \(thrown)"
        )
        return thrown
    }

    private func isSQLiteError(_ error: JMDictLookupError) -> Bool {
        if case .sqliteError = error {
            return true
        }
        return false
    }

    /// A headword row whose entry row is gone is a corrupt database, not a
    /// miss — the lookup throws instead of returning nil.
    @Test("a headword row without its entry throws a sqlite error")
    func orphanHeadwordRowThrows() throws {
        let built = try makeOrphanHeadwordDatabase()
        let sut = JMDictLookup(resolveDatabase: { [url = built.url] in url })
        defer {
            sut.close()
            built.remove()
        }

        let thrown = try #require(
            #expect(throws: JMDictLookupError.self) {
                try sut.lookup(LookupCandidate(text: "孤語"))
            }
        )

        guard case .sqliteError = thrown else {
            Issue.record("expected .sqliteError, got \(thrown)")
            return
        }
    }

    /// Minimal two-table database (the full fixture is unnecessary for this
    /// path): one headwords row whose entry_id has no matching entries row.
    private func makeOrphanHeadwordDatabase() throws -> JMDictFixtureDatabase.Built {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-jmdict-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("jmdict-orphan.sqlite")

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            throw JMDictFixtureDatabase.FixtureError.sqlite("orphan fixture open failed")
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
            INSERT INTO headwords VALUES (777, '孤語', 'keb', NULL, NULL, NULL, NULL);
            """,
            nil, nil, nil
        ) == SQLITE_OK else {
            throw JMDictFixtureDatabase.FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return JMDictFixtureDatabase.Built(url: url)
    }
}

// MARK: - Live database

/// Exercises the real prepared JMDict database when one resolves (the
/// Application Support location, or — debug checkouts — the uncompressed
/// intermediate `scripts/build_jmdict.sh` leaves in `build/`). Opt-in like
/// the other `Live*` suites: it re-runs at every pin bump and pins the
/// spot entries against the shipped data shape.
/// Same resolution chain as `JMDictLookup.defaultDatabaseURL`, with a
/// repo-root fallback the test host's working directory can't provide.
/// File-scope so the suite trait can gate on it.
private let liveDatabaseURL: URL? = {
    if let resolved = JMDictLookup.defaultDatabaseURL {
        return resolved
    }
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let checkout = repoRoot.appendingPathComponent("build/\(JMDictPin.preparedFileName)")
    return FileManager.default.fileExists(atPath: checkout.path) ? checkout : nil
}()

@Suite("JMDictLookup live database", .enabled(if: liveDatabaseURL != nil))
struct JMDictLookupLiveTests {
    private let engine: JMDictLookup

    init() throws {
        let url = try #require(liveDatabaseURL)
        engine = JMDictLookup(resolveDatabase: { url })
    }

    @Test("hits 食べる with its pitch and JLPT from the real database")
    func taberu() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "食べる")))

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 1_358_280)
        #expect(entry.common)
        #expect(entry.jlpt == 5)
        #expect(entry.zoPatts == "LHLL")
        #expect(entry.senses[0].glosses == ["to eat"])
    }

    @Test("hits the kana-only gairaigo アルバイト from the real database")
    func arubaito() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "アルバイト")))

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 1_019_420)
        #expect(entry.keb == nil)
        #expect(entry.common)
        #expect(entry.jlpt == 4)
    }

    @Test("hits 橋 with its pitch from the real database")
    func hashi() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "橋")))

        let entry = try #require(result.entries.first)
        #expect(entry.entSeq == 1_237_410)
        #expect(entry.common)
        #expect(entry.jlpt == 5)
        #expect(entry.zoPatts == "HLL")
    }

    @Test("returns multiple homograph entries for あめ in ranked order")
    func ameHomographs() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あめ")))

        #expect(result.entries.count >= 2)
        #expect(result.entries.first?.common == true)
    }

    @Test("ranks the 前/まえ entry first when the furigana reading is まえ")
    func maeReadingMatch() throws {
        let result = try #require(try engine.lookup(
            LookupCandidate(text: "前", reading: "まえ")
        ))

        #expect(result.entries.count >= 2)
        #expect(result.entries.first?.reb == "まえ")
    }
}
