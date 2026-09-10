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
    /// The kana reading the tap's furigana (or kana surface) shows — after
    /// the surface-writing match, entries whose entry reading matches rank
    /// first within the result, since the displayed furigana reflects the
    /// reading in context. nil when the tap carries no readable kana; the
    /// ranking then ignores it.
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
/// entry sharing that headword, ranked surface-writing match first (the
/// entry written the way the tap is written leads), then furigana
/// reading-match, then common-first, then `ent_seq` — the stable order an
/// entry pager walks.
struct LookupResult: Equatable, Sendable {
    let matched: String
    let entries: [JMDictEntry]
}

/// Ordered-candidate outcome: the first hit leads the display result — its
/// `displayOrigin` names the candidate role that produced it (a join lead
/// carries `.join` so the UI can label the compound match); later
/// candidates whose entries add something new are retained as the "also:"
/// hits, longest match first (ties keep candidate order).
struct LookupOutcome: Equatable, Sendable {
    let display: LookupResult
    let displayOrigin: ExpansionOrigin
    let also: [LookupResult]
}

/// A tap's resolution: found — the tapped word's own surface or lemma, or
/// the join it leads, matched an entry — or not-found, where the tapped
/// word itself has no entry and only the deep kanji-split fallbacks hit.
/// A not-found resolution never promotes a split to the display result;
/// its hits travel as `related`, which the UI demotes to suggestions.
enum LookupResolution: Equatable, Sendable {
    case found(LookupOutcome)
    case notFound(related: [LookupResult])
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
    /// Guarded by `lock` (every query runs under it). Compiled once per SQL
    /// against the long-lived handle and reset between uses — lookups run
    /// several statements per tap, and `sqlite3_prepare_v2` dominates a
    /// repeat query's cost. Callers fully consume each statement (step to
    /// `SQLITE_DONE` or return) before returning, so reuse is safe; a
    /// statement left mid-step is reset before its next use anyway.
    private var preparedStatements: [String: OpaquePointer] = [:]

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
            releasePreparedStatements()
            sqlite3_close_v2(handle)
        }
    }

    // MARK: - Queries

    /// Looks up a single candidate; nil when nothing matches.
    func lookup(_ candidate: LookupCandidate) throws -> LookupResult? {
        try lookup([candidate])?.display
    }

    /// Looks up candidates in order; the first hit is the display result and
    /// later hits adding entries are kept as "also". The expansion-aware
    /// typed variant (`lookup(_ candidates: [ExpansionCandidate])`)
    /// additionally classifies a split-only tap as not-found; this untyped
    /// entry treats every candidate as the tapped word itself, so its
    /// outcome's `displayOrigin` is always `.tappedSurface`.
    func lookup(_ candidates: [LookupCandidate]) throws -> LookupOutcome? {
        guard case let .found(outcome) = try lookup(candidates.map { ExpansionCandidate(
            candidate: $0, origin: .tappedSurface
        ) }) else { return nil }
        return outcome
    }

    /// Resolves expansion candidates in order, classifying by origin: the
    /// tapped word's surface or lemma — or the join it leads — makes the
    /// found outcome (first hit displays; later hits adding new entries are
    /// retained as "also:", longest match first with ties keeping candidate
    /// order, and a candidate that only re-hits already-returned entries is
    /// redundant and skipped). A split can never lead: a tap whose first
    /// hit is a split resolves not-found, every split hit demoted to the
    /// related list (same redundancy rule — a hit only re-resolving known
    /// entries is skipped), longest match first. Every candidate missing →
    /// `.notFound(related: [])`; any infrastructure error aborts the whole
    /// lookup as a throw (never downgraded to a miss).
    func lookup(_ candidates: [ExpansionCandidate]) throws -> LookupResolution {
        var display: LookupResult?
        var displayOrigin: ExpansionOrigin?
        var also: [LookupResult] = []
        var related: [LookupResult] = []
        var seenEntryIDs: Set<Int> = []
        for expansion in candidates {
            guard let result = try lookupResult(for: expansion.candidate) else { continue }
            let entryIDs = Set(result.entries.map(\.entSeq))
            if display == nil, expansion.origin == .split {
                // Same redundancy rule as "also": a hit whose every entry
                // was already resolved is a duplicate pill, not new
                // information.
                if !entryIDs.isSubset(of: seenEntryIDs) {
                    related.append(result)
                }
            } else if display == nil {
                // Expansion order guarantees every non-split candidate
                // precedes the splits, so this branch can never strand
                // collected related hits (they would be dropped by the
                // found return below).
                assert(related.isEmpty, "non-split hit after split hits: \(expansion)")
                display = result
                displayOrigin = expansion.origin
            } else if !entryIDs.isSubset(of: seenEntryIDs) {
                also.append(result)
            }
            seenEntryIDs.formUnion(entryIDs)
        }
        if let display, let displayOrigin {
            return .found(LookupOutcome(
                display: display, displayOrigin: displayOrigin,
                also: Self.longestFirst(also)
            ))
        }
        return .notFound(related: Self.longestFirst(related))
    }

    /// Longest match first, explicitly stable: candidates arrive in
    /// expansion order (longest-first joins, then splits), so equal lengths
    /// keep that order.
    private static func longestFirst(_ results: [LookupResult]) -> [LookupResult] {
        results.enumerated().sorted { lhs, rhs in
            if lhs.element.matched.count != rhs.element.matched.count {
                return lhs.element.matched.count > rhs.element.matched.count
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    /// Releases the database handle. The instance stays closed permanently —
    /// a testing seam for the closed-handle error path (the app never closes).
    func close() {
        lock.withLock {
            if case let .open(handle) = state {
                releasePreparedStatements()
                sqlite3_close_v2(handle)
            }
            state = .closed
        }
    }

    // MARK: - Reading fallback

    /// The kana reading of the best kanji-writing entry for `writing`, or nil
    /// when no kanji-writing headword matches. The annotator's fallback for
    /// kanji surfaces the tokenizer lexicon can't read (IPADIC has no
    /// standalone entry for 圧, 灼, … — they tokenize as unknown words with a
    /// `*` reading; JMDict covers them). Deliberately minimal — one indexed
    /// `headwords` hit plus one `entries` row, no sense fetching — ranked
    /// common-first then `ent_seq`, the same leading order the display lookup
    /// ranks to. The entry reading folds to hiragana so the fallback meets
    /// the annotator's kana contracts (IPADIC readings arrive hiragana via
    /// the runtime; KanaRomaji and the furigana alignment fold anyway).
    /// Throws on infrastructure failure; callers degrade to unannotated.
    func reading(forWriting writing: String) throws -> String? {
        try lock.withLock {
            let db = try openedDatabase()
            let statement = try prepare(
                """
                SELECT e.reb FROM entries e
                JOIN headwords h ON h.entry_id = e.ent_seq
                WHERE h.text = ? AND h.kind = 'keb'
                ORDER BY e.common DESC, e.ent_seq
                LIMIT 1
                """, db
            )
            sqlite3_bind_text(statement, 1, writing, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let reb = optionalText(statement, 0)
            else { return nil }
            return ReadingAlignment.foldedKana(reb)
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
            // The tapped surface names the writing in context, so the entry
            // written the way the tap is written leads the pager (a kana
            // tap leads with the kana-only entry, a kanji tap with its own
            // kanji writing); the furigana names the reading, and
            // commonness and ent_seq break the remaining ties.
            let surface = Self.foldedKana(candidate.text)
            func matchesSurface(_ entry: JMDictEntry) -> Bool {
                guard let written = entry.keb ?? entry.reb else { return false }
                return Self.foldedKana(written) == surface
            }
            let expected = candidate.reading.map(Self.foldedKana)
            func matchesReading(_ entry: JMDictEntry) -> Bool {
                guard let expected, let reb = entry.reb else { return false }
                return Self.foldedKana(reb) == expected
            }
            entries.sort {
                if matchesSurface($0) != matchesSurface($1) {
                    return matchesSurface($0)
                }
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
        if let cached = preparedStatements[sql] {
            // Reset unwinds any prior step (a row-loop that returned early or
            // an error) and drops its bindings; the statement is then ready
            // for fresh binds.
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        preparedStatements[sql] = statement
        return statement
    }

    /// Finalizes every cached statement — must run before the handle closes.
    private func releasePreparedStatements() {
        for statement in preparedStatements.values {
            sqlite3_finalize(statement)
        }
        preparedStatements.removeAll()
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
