import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` — SQLite's destructor constant is not exposed to Swift
/// directly; -1 instructs SQLite to copy the bound string immediately.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One lookup candidate: the exact string queried against `headwords.text`,
/// plus the headword kind the sense restriction filter is honored against.
struct LookupCandidate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Kanji-bearing writing (the DB's `keb` headword rows).
        case kanji
        /// Kana reading (the DB's `reb` headword rows).
        case kana
    }

    let text: String
    let kind: Kind
    /// The kana reading the tap's furigana (or kana surface) shows — entries
    /// whose entry reading matches rank first within the result, since the
    /// displayed furigana reflects the reading in context. nil when the tap
    /// carries no readable kana; the ranking then ignores it.
    let reading: String?

    /// `kind` defaults to a script derivation: any ideographic scalar makes
    /// the candidate a kanji writing, anything else (hiragana, katakana,
    /// bare Latin) a reading.
    init(text: String, kind: Kind? = nil, reading: String? = nil) {
        self.text = text
        self.kind = kind ?? {
            let ideographic = text.unicodeScalars.contains { $0.properties.isIdeographic }
            return ideographic ? .kanji : .kana
        }()
        self.reading = reading
    }
}

/// One sense of a JMDict entry.
struct JMDictSense: Equatable, Sendable {
    /// Comma-joined part-of-speech tags as stored (`"n,vs,vi"`), or nil.
    let pos: String?
    let glosses: [String]
    /// Comma-space-joined misc tags as stored (`"col, uk"`), or nil.
    let misc: String?
    /// Kanji-writing restriction: nil = applies to every writing; non-nil =
    /// the exact writings it applies to (an empty array matches none —
    /// defensive, upstream never emits an empty list at sense level).
    let restrictedKanji: [String]?
    /// Same restriction semantics over kana readings.
    let restrictedKana: [String]?
}

/// One JMDict entry. `jlpt` and the pitch fields come from the headword row
/// the candidate matched (per-writing values); `common` is entry-level.
struct JMDictEntry: Equatable, Sendable {
    let entSeq: Int
    let keb: String?
    let reb: String?
    let common: Bool
    let jlpt: Int?
    /// Verbatim Wadoku hatsuon text. Render-time gating (marked-up forms
    /// containing `< > [ ] ･ ~` are omitted) belongs to the UI layer.
    let hatsuon: String?
    let accPatts: String?
    /// Verbatim H/L pattern string (alphabet `H L h l ,` — not assumed pure).
    let zoPatts: String?
    let senses: [JMDictSense]
}

/// One candidate's lookup outcome: the exact string that matched and every
/// entry sharing that headword, ranked reading-match first when the
/// candidate carries a furigana reading, then common-first, then
/// `ent_seq` — the stable order an entry pager walks.
struct LookupResult: Equatable, Sendable {
    let matched: String
    let entries: [JMDictEntry]
}

/// Ordered-candidate outcome: the first candidate that hit is the display
/// result; later candidates whose entries add something new are retained as
/// the "also:" shorter hits, in candidate order.
struct LookupOutcome: Equatable, Sendable {
    let display: LookupResult
    let also: [LookupResult]
}

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
            return "JMDict database not found; the dictionary may still be preparing."
        case .databaseClosed:
            return "JMDict database has been closed."
        case let .sqliteError(code, message):
            return "JMDict database error \(code): \(message)."
        }
    }
}

/// Read-only lookup engine over the prepared JMDict SQLite database
/// (`jmdict-<tag>.sqlite`). Uses the system SQLite via `import SQLite3` —
/// no new dependency — and every query is an exact `headwords.text = ?`
/// hit on the build's B-tree index.
///
/// Sendable by locking contract (same stance as `DictionaryEngine`): the
/// only mutable state is the lazily opened SQLite handle, guarded by
/// `lock`, and every query runs under it.
final class JMDictLookup: @unchecked Sendable {
    private enum State {
        case idle
        case open(OpaquePointer)
        case closed
    }

    private let lock = NSLock()
    private let resolveDatabase: () -> URL?
    /// Guarded by `lock`. Opened lazily on the first query and kept warm; a
    /// failed open is never cached, so a later call retries naturally (the
    /// database may still be preparing). `close()` is permanent for this
    /// instance — subsequent queries throw `.databaseClosed`.
    private var state: State = .idle

    /// Where the prepared JMDict database lives: the Application Support
    /// location `DictionaryStore` promotes into, or — debug checkouts only —
    /// the uncompressed intermediate `scripts/build_jmdict.sh` leaves in
    /// `build/` before compressing.
    static var defaultDatabaseURL: URL? {
        defaultDatabaseURL(
            destination: DictionaryStore.defaultDestinationDirectory,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    /// Injected core of `defaultDatabaseURL`: the prepared Application
    /// Support location first, then the debug checkout, then none.
    static func defaultDatabaseURL(
        destination: URL, fileExists: (URL) -> Bool
    ) -> URL? {
        let prepared = destination.appendingPathComponent(JMDictPin.preparedFileName)
        if fileExists(prepared) {
            return prepared
        }
        #if DEBUG
            let checkout = URL(fileURLWithPath: "build/\(JMDictPin.preparedFileName)")
            if fileExists(checkout) {
                return checkout
            }
        #endif
        return nil
    }

    /// `resolveDatabase` is injectable for tests; the default resolves the
    /// prepared database location above.
    init(resolveDatabase: @escaping () -> URL? = { JMDictLookup.defaultDatabaseURL }) {
        self.resolveDatabase = resolveDatabase
    }

    deinit {
        if case let .open(handle) = state {
            sqlite3_close_v2(handle)
        }
    }

    // MARK: - Queries

    /// Looks up a single candidate; nil when nothing matches.
    func lookup(_ candidate: LookupCandidate) throws -> LookupResult? {
        try lookup([candidate])?.display
    }

    /// Looks up candidates in order (per tap: the forward-expansion joins
    /// longest-first, then the tapped segment's lemma and surface — see
    /// `JMDictExpansion.candidates`). The first
    /// candidate that hit is the display result; later candidates whose
    /// entries add something new are retained as "also:" results in order —
    /// a candidate that only re-hits already-returned entries is redundant
    /// and skipped. Every candidate missing → nil; any infrastructure error
    /// aborts the whole lookup as a throw (never downgraded to a miss).
    func lookup(_ candidates: [LookupCandidate]) throws -> LookupOutcome? {
        guard !candidates.isEmpty else { return nil }
        var display: LookupResult?
        var also: [LookupResult] = []
        var seenEntryIDs: Set<Int> = []
        for candidate in candidates {
            guard let result = try lookupResult(for: candidate) else { continue }
            let entryIDs = Set(result.entries.map(\.entSeq))
            if display == nil {
                display = result
            } else if !entryIDs.isSubset(of: seenEntryIDs) {
                also.append(result)
            }
            seenEntryIDs.formUnion(entryIDs)
        }
        guard let display else { return nil }
        return LookupOutcome(display: display, also: also)
    }

    /// Releases the database handle. The instance stays closed permanently —
    /// a testing seam for the closed-handle error path (the app never closes).
    func close() {
        lock.withLock {
            if case let .open(handle) = state {
                sqlite3_close_v2(handle)
            }
            state = .closed
        }
    }

    // MARK: - Core (lock-held)

    private func lookupResult(for candidate: LookupCandidate) throws -> LookupResult? {
        try lock.withLock {
            let db = try openedDatabase()
            var rowByEntry: [Int: HeadwordRow] = [:]
            for row in try headwordRows(matching: candidate.text, db: db)
                where rowByEntry[row.entryID] == nil
            {
                // Multiple headword rows can reference one entry (kanji and
                // kana spellings coincide); the first row wins for JLPT/pitch.
                rowByEntry[row.entryID] = row
            }
            var entries: [JMDictEntry] = []
            entries.reserveCapacity(rowByEntry.count)
            for (entSeq, row) in rowByEntry {
                if let entry = try entry(
                    entSeq: entSeq, headword: row, candidate: candidate, db: db
                ) {
                    entries.append(entry)
                }
            }
            // An entry whose every sense was restriction-filtered away has
            // no displayable definition and contributes nothing.
            guard !entries.isEmpty else { return nil }
            // The tap's furigana names the reading in context, so the
            // entry pronounced that way leads the pager; commonness and
            // ent_seq break the remaining ties.
            let expected = candidate.reading.map(Self.foldedKana)
            func matchesReading(_ entry: JMDictEntry) -> Bool {
                guard let expected, let reb = entry.reb else { return false }
                return Self.foldedKana(reb) == expected
            }
            entries.sort {
                let lhsMatch = matchesReading($0)
                let rhsMatch = matchesReading($1)
                if lhsMatch != rhsMatch {
                    return lhsMatch
                }
                if $0.common != $1.common {
                    return $0.common
                }
                return $0.entSeq < $1.entSeq
            }
            return LookupResult(matched: candidate.text, entries: entries)
        }
    }

    private struct HeadwordRow {
        let entryID: Int
        let jlpt: Int?
        let hatsuon: String?
        let accPatts: String?
        let zoPatts: String?
    }

    private func headwordRows(matching text: String, db: OpaquePointer) throws -> [HeadwordRow] {
        let statement = try prepare(
            "SELECT entry_id, jlpt, hatsuon, acc, zo FROM headwords WHERE text = ?", db
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, text, -1, sqliteTransient)
        var rows: [HeadwordRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(HeadwordRow(
                    entryID: Int(sqlite3_column_int64(statement, 0)),
                    jlpt: optionalInt(statement, 1),
                    hatsuon: optionalText(statement, 2),
                    accPatts: optionalText(statement, 3),
                    zoPatts: optionalText(statement, 4)
                ))
            case SQLITE_DONE:
                return rows
            default:
                throw sqliteError(db)
            }
        }
    }

    private func entry(
        entSeq: Int, headword: HeadwordRow, candidate: LookupCandidate, db: OpaquePointer
    ) throws -> JMDictEntry? {
        let entryStatement = try prepare(
            "SELECT keb, reb, common FROM entries WHERE ent_seq = ?", db
        )
        defer { sqlite3_finalize(entryStatement) }
        sqlite3_bind_int64(entryStatement, 1, Int64(entSeq))
        guard sqlite3_step(entryStatement) == SQLITE_ROW else {
            // A headword row always references an existing entry; a missing
            // parent is a corrupt database, not a miss.
            throw sqliteError(db)
        }
        let keb = optionalText(entryStatement, 0)
        let reb = optionalText(entryStatement, 1)
        let common = sqlite3_column_int(entryStatement, 2) != 0

        let senseStatement = try prepare(
            "SELECT pos, gloss, misc, skeb, sreb FROM senses WHERE entry_id = ? ORDER BY ord", db
        )
        defer { sqlite3_finalize(senseStatement) }
        sqlite3_bind_int64(senseStatement, 1, Int64(entSeq))
        var senses: [JMDictSense] = []
        while true {
            switch sqlite3_step(senseStatement) {
            case SQLITE_ROW:
                let pos = optionalText(senseStatement, 0)
                let glossText = optionalText(senseStatement, 1) ?? ""
                let misc = optionalText(senseStatement, 2)
                let restrictedKanji = Self.restrictedWritings(optionalText(senseStatement, 3))
                let restrictedKana = Self.restrictedWritings(optionalText(senseStatement, 4))
                let restricted = candidate.kind == .kanji ? restrictedKanji : restrictedKana
                if let restricted, !restricted.contains(candidate.text) {
                    continue
                }
                senses.append(JMDictSense(
                    pos: pos,
                    glosses: glossText.isEmpty ? [] : glossText.components(separatedBy: "; "),
                    misc: misc,
                    restrictedKanji: restrictedKanji,
                    restrictedKana: restrictedKana
                ))
            case SQLITE_DONE:
                if senses.isEmpty {
                    return nil
                }
                return JMDictEntry(
                    entSeq: entSeq,
                    keb: keb,
                    reb: reb,
                    common: common,
                    jlpt: headword.jlpt,
                    hatsuon: headword.hatsuon,
                    accPatts: headword.accPatts,
                    zoPatts: headword.zoPatts,
                    senses: senses
                )
            default:
                throw sqliteError(db)
            }
        }
    }

    // MARK: - Database lifecycle (lock-held)

    private func openedDatabase() throws -> OpaquePointer {
        switch state {
        case let .open(handle):
            return handle
        case .closed:
            throw JMDictLookupError.databaseClosed
        case .idle:
            break
        }
        guard let url = resolveDatabase(), FileManager.default.fileExists(atPath: url.path) else {
            throw JMDictLookupError.databaseMissing
        }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let opened
        else {
            let failure = opened.map { handle in
                JMDictLookupError.sqliteError(
                    code: sqlite3_errcode(handle),
                    message: String(cString: sqlite3_errmsg(handle))
                )
            } ?? JMDictLookupError.databaseMissing
            sqlite3_close_v2(opened)
            throw failure
        }
        state = .open(opened)
        return opened
    }

    // MARK: - SQLite plumbing

    private func prepare(_ sql: String, _ db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        return statement
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func optionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func sqliteError(_ db: OpaquePointer) -> JMDictLookupError {
        .sqliteError(
            code: sqlite3_errcode(db),
            message: String(cString: sqlite3_errmsg(db))
        )
    }

    /// Parses the build's `skeb`/`sreb` column: NULL = applies to every
    /// writing; otherwise a JSON array of writings (an empty array matches
    /// none — the build's defensive normalization). A stray `"*"` inside the
    /// array is honored as "every writing" as well.
    private static func restrictedWritings(_ raw: String?) -> [String]? {
        guard let raw, let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return list.contains("*") ? nil : list
    }

    /// Kana-folded comparison text for reading-match ranking: katakana
    /// readings (the DB stores both shapes) fold onto hiragana so a
    /// katakana furigana matches its hiragana entry reading and vice versa.
    private static func foldedKana(_ text: String) -> String {
        ReadingAlignment.foldedKana(text)
    }
}
