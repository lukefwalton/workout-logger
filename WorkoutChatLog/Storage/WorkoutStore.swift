import Foundation

/// The one disciplined layer. Owns all SQL and the single write path. The app
/// (and, later, the on-device model) proposes a `WorkoutDraft`; this type
/// validates it, resolves each exercise against the canonical registry, and
/// writes it atomically. Nothing else writes to the database, and the model
/// never generates SQL.
///
/// The implementation is split by domain so no single file carries the whole
/// store:
///   - `WorkoutStore+Sessions.swift`     — the one workout write path + session/set edits
///   - `WorkoutStore+History.swift`      — non-isolated set/session reads (History, Progress, share)
///   - `WorkoutStore+Exercises.swift`    — the exercise registry: seeding, resolution, management
///   - `WorkoutStore+Supplements.swift`  — daily supplement tracking (schema v2)
///   - `WorkoutStore+Cardio.swift`       — cardio bouts (schema v3)
///   - `WorkoutStore+ImportExport.swift` — JSON export + merging import
/// It is still one type on one connection, so the invariants (single-open
/// session, registry resolution inside the save transaction) remain enforced
/// in one place; the split is file organization, not a change of ownership.
///
/// `@unchecked Sendable` is sound because the only stored property is
/// `SQLiteDB`, which serializes whole transaction closures on a recursive
/// connection lock (FULLMUTEX alone only covers single C calls — see
/// `SQLiteDB`'s doc). Writes are additionally `@MainActor`-gated; reads go
/// through `db.readTransaction`, so an off-main read can never interleave
/// into an open write transaction or see half a workout. This keeps off-main
/// History/Progress reads legal — `setHistory` is a hot, scrolling-frequency
/// call after a year of data. Multi-read consumers get consistency via
/// `snapshot(_:)`.
final class WorkoutStore: @unchecked Sendable {
    /// The one connection. Internal rather than `private` only because Swift's
    /// `private` is file-scoped and the domain extension files above need it.
    /// It is still store-internal by contract: feature code goes through the
    /// typed API, so every workout write funnels into `save`. Part of the
    /// guarded surface — `scripts/check_store_boundary.sh` fails CI on any
    /// reference outside `WorkoutChatLog/Storage/`.
    let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    @MainActor
    func migrate() throws {
        try Schema.migrate(db)
    }

    /// The applied schema version. Exposed for diagnostics/tests; the raw
    /// connection stays store-internal so feature code can't run ad hoc SQL and
    /// bypass validation — every workout write goes through `save`. Wrapped in
    /// `readTransaction` like every other store read — a lone PRAGMA would be
    /// harmless mid-transaction, but the serialized-read rule is only useful
    /// if it has no exceptions.
    func schemaVersion() throws -> Int {
        try db.readTransaction { try db.userVersion() }
    }

    // MARK: - Shared plumbing (used by the domain extension files)

    /// Run several reads as one consistent snapshot: a single deferred read
    /// transaction, serialized against writes on this connection, so a save
    /// committing mid-snapshot can't make two reads disagree (e.g. History's
    /// session rows vs. its cardio list). Nests harmlessly around the store's
    /// individually-wrapped reads. Read-only by ENFORCEMENT, not just
    /// contract: a write through the domain APIs hits `transaction`'s
    /// nested-write diagnostic, and even a raw Storage-internal write
    /// statement is refused at prepare time (`sqlite3_stmt_readonly`) — both
    /// roll the snapshot back and are pinned in `SQLiteDBTests` /
    /// `WorkoutStoreTests`.
    func snapshot<T>(_ body: () throws -> T) throws -> T {
        try db.readTransaction(body)
    }

    /// Row count for one of the store's own tables, shared by the domain
    /// files. Deliberately takes a bare table identifier rather than SQL text
    /// and builds the statement here: an earlier draft took a raw SQL string,
    /// which — being cross-file `internal` — was an ad hoc SQL escape hatch
    /// around the store's boundary ("feature code never runs SQL"). The
    /// identifier is validated so it can't smuggle a clause, and the built
    /// statement is a SELECT, so this helper can never write.
    func count(inTable table: String) throws -> Int {
        precondition(table.allSatisfy { $0.isLetter || $0 == "_" },
                     "count(inTable:) takes a bare table identifier, never SQL")
        return try db.readTransaction {
            let stmt = try db.prepare("SELECT COUNT(*) FROM \(table);")
            defer { stmt.finalize() }
            return try stmt.step() ? Int(stmt.int(0)) : 0
        }
    }

    // MARK: - Encoding helpers

    static func iso(_ date: Date) -> String { WorkoutDateFormat.string(date) }

    /// Parses an ISO8601 timestamp the store wrote with `iso(_:)`. nil for nil or
    /// unparseable input (e.g. a NULL ended_at on an open session).
    static func date(_ text: String?) -> Date? { WorkoutDateFormat.date(text) }

    static func decodeStringArray(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array
    }
}
