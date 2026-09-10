import Foundation

/// Read-only lookup engine over the prepared JMDict SQLite database
/// (`jmdict-<tag>.sqlite`). Uses the system SQLite through `SQLiteDatabase` —
/// no new dependency — and every query is an exact `headwords.text = ?`
/// hit on the build's B-tree index.
///
/// Sendable by locking contract (same stance as `DictionaryEngine`): the
/// only mutable state is the lazily opened database, guarded by `lock`, and
/// every query runs under it.
final class JMDictLookup: @unchecked Sendable {
    private enum State {
        case idle
        case open(SQLiteDatabase)
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
            let checkout = URL(fileURLWithPath: JMDictPin.debugCheckoutPath)
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
        close()
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
            if case let .open(database) = state {
                database.close()
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
        do {
            return try lock.withLock {
                let db = try openedDatabase()
                let statement = try db.statement(Self.readingSQL)
                statement.bind(writing, at: 1)
                guard try statement.step(), let reb = statement.optionalText(0) else {
                    return nil
                }
                return ReadingAlignment.foldedKana(reb)
            }
        } catch let error as SQLiteDatabase.Error {
            throw JMDictLookupError(error)
        }
    }

    // MARK: - Core (lock-held)

    private func lookupResult(for candidate: LookupCandidate) throws -> LookupResult? {
        do {
            return try lock.withLock {
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
                let surface = ReadingAlignment.foldedKana(candidate.text)
                let expected = candidate.reading.map(ReadingAlignment.foldedKana)
                let ranked = entries.map { entry -> RankedEntry in
                    let matchesSurface = (entry.keb ?? entry.reb).map {
                        ReadingAlignment.foldedKana($0) == surface
                    } ?? false
                    let matchesReading: Bool
                    if let expected, let reb = entry.reb {
                        matchesReading = ReadingAlignment.foldedKana(reb) == expected
                    } else {
                        matchesReading = false
                    }
                    return RankedEntry(
                        surface: matchesSurface, reading: matchesReading, entry: entry
                    )
                }.sorted {
                    if $0.surface != $1.surface {
                        return $0.surface
                    }
                    if $0.reading != $1.reading {
                        return $0.reading
                    }
                    if $0.entry.common != $1.entry.common {
                        return $0.entry.common
                    }
                    return $0.entry.entSeq < $1.entry.entSeq
                }
                return LookupResult(matched: candidate.text, entries: ranked.map(\.entry))
            }
        } catch let error as SQLiteDatabase.Error {
            throw JMDictLookupError(error)
        }
    }

    private struct HeadwordRow {
        let entryID: Int
        let jlpt: Int?
        let hatsuon: String?
        let accPatts: String?
        let zoPatts: String?
    }

    private struct RankedEntry {
        let surface: Bool
        let reading: Bool
        let entry: JMDictEntry
    }

    private func headwordRows(matching text: String, db: SQLiteDatabase) throws -> [HeadwordRow] {
        let statement = try db.statement(Self.headwordRowsSQL)
        statement.bind(text, at: 1)
        var rows: [HeadwordRow] = []
        while try statement.step() {
            rows.append(HeadwordRow(
                entryID: statement.requiredInt(0),
                jlpt: statement.optionalInt(1),
                hatsuon: statement.optionalText(2),
                accPatts: statement.optionalText(3),
                zoPatts: statement.optionalText(4)
            ))
        }
        return rows
    }

    private func entry(
        entSeq: Int, headword: HeadwordRow, candidate: LookupCandidate, db: SQLiteDatabase
    ) throws -> JMDictEntry? {
        let entryStatement = try db.statement(Self.entrySQL)
        entryStatement.bind(entSeq, at: 1)
        guard try entryStatement.step() else {
            // A headword row always references an existing entry; a missing
            // parent is a corrupt database, not a miss.
            throw JMDictLookupError(db.lastError())
        }
        let keb = entryStatement.optionalText(0)
        let reb = entryStatement.optionalText(1)
        let common = entryStatement.bool(2)

        let senses = try self.senses(entSeq: entSeq, candidate: candidate, db: db)
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
    }

    private func senses(
        entSeq: Int, candidate: LookupCandidate, db: SQLiteDatabase
    ) throws -> [JMDictSense] {
        let statement = try db.statement(Self.senseSQL)
        statement.bind(entSeq, at: 1)
        var senses: [JMDictSense] = []
        while try statement.step() {
            let pos = statement.optionalText(0)
            let glossText = statement.optionalText(1) ?? ""
            let misc = statement.optionalText(2)
            let restrictedKanji = Self.restrictedWritings(statement.optionalText(3))
            let restrictedKana = Self.restrictedWritings(statement.optionalText(4))
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
        }
        return senses
    }

    // MARK: - Database lifecycle (lock-held)

    private func openedDatabase() throws -> SQLiteDatabase {
        switch state {
        case let .open(database):
            return database
        case .closed:
            throw JMDictLookupError.databaseClosed
        case .idle:
            break
        }
        guard let url = resolveDatabase(), FileManager.default.fileExists(atPath: url.path) else {
            throw JMDictLookupError.databaseMissing
        }
        let database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(path: url.path)
        } catch {
            throw JMDictLookupError(error)
        }
        state = .open(database)
        return database
    }

    // MARK: - SQL

    private static let readingSQL = """
    SELECT e.reb FROM entries e
    JOIN headwords h ON h.entry_id = e.ent_seq
    WHERE h.text = ? AND h.kind = 'keb'
    ORDER BY e.common DESC, e.ent_seq
    LIMIT 1
    """
    private static let headwordRowsSQL =
        "SELECT entry_id, jlpt, hatsuon, acc, zo FROM headwords WHERE text = ?"
    private static let entrySQL = "SELECT keb, reb, common FROM entries WHERE ent_seq = ?"
    private static let senseSQL =
        "SELECT pos, gloss, misc, skeb, sreb FROM senses WHERE entry_id = ? ORDER BY ord"

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
}

extension JMDictLookupError {
    /// Maps a generic SQLite failure onto the lookup's typed error surface.
    init(_ error: SQLiteDatabase.Error) {
        switch error {
        case .unavailable:
            self = .databaseMissing
        case let .sqlite(code, message):
            self = .sqliteError(code: code, message: message)
        }
    }
}
