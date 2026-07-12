import Foundation

/// Cardio bouts (schema v3): the one cardio write path, reads, and deletion.
/// Every fresh write to `cardio_entries` lives in this file (the import path's
/// raw insert lives with the rest of import in `WorkoutStore+ImportExport.swift`,
/// because `SQLiteDB.transaction` doesn't nest).
extension WorkoutStore {
    // MARK: - Cardio (schema v3)

    /// The one cardio write path — the cardio twin of `save`. The parser proposes
    /// a `CardioDraft`, the confirm card lets the user fix it, and only here is it
    /// written. `CardioValidator.normalized` coerces rather than rejects (cardio
    /// never fails to ingest), so the row that lands is always sane.
    @MainActor
    @discardableResult
    func saveCardio(_ draft: CardioDraft) throws -> Int64 {
        let clean = CardioValidator.normalized(draft)
        return try db.transaction {
            let stmt = try db.prepare("""
                INSERT INTO cardio_entries
                  (activity, duration_seconds, distance, distance_unit, notes, source_text, logged_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { stmt.finalize() }
            stmt.bind(text: clean.activity, at: 1)
            stmt.bind(optionalInt: clean.durationSeconds, at: 2)
            stmt.bind(optionalDouble: clean.distance, at: 3)
            stmt.bind(optionalText: clean.distanceUnit?.rawValue, at: 4)
            stmt.bind(optionalText: clean.notes, at: 5)
            stmt.bind(optionalText: clean.sourceText, at: 6)
            stmt.bind(text: Self.iso(clean.loggedAt), at: 7)
            stmt.bind(text: Self.iso(Date()), at: 8)
            try stmt.step()
            return db.lastInsertRowID
        }
    }

    /// Logged cardio bouts, newest first, optionally since a date. Non-isolated
    /// read so History can fetch off the main thread like `setHistory`.
    func cardioEntries(since: Date? = nil) throws -> [CardioEntry] {
        let start = since.map(Self.iso)
        let stmt = try db.prepare("""
            SELECT id, activity, duration_seconds, distance, distance_unit, notes, source_text, logged_at
            FROM cardio_entries
            WHERE (? IS NULL OR logged_at >= ?)
            ORDER BY logged_at DESC, id DESC;
        """)
        defer { stmt.finalize() }
        stmt.bind(optionalText: start, at: 1)
        stmt.bind(optionalText: start, at: 2)
        var rows: [CardioEntry] = []
        while try stmt.step() {
            rows.append(CardioEntry(id: stmt.int(0),
                                    activity: stmt.text(1) ?? CardioActivity.generic.display,
                                    durationSeconds: stmt.optionalInt(2),
                                    distance: stmt.optionalDouble(3),
                                    distanceUnit: stmt.text(4).flatMap(CardioDistanceUnit.init(rawValue:)),
                                    notes: stmt.text(5),
                                    sourceText: stmt.text(6),
                                    loggedAt: Self.date(stmt.text(7)) ?? Date()))
        }
        return rows
    }

    func cardioCount() throws -> Int { try count("SELECT COUNT(*) FROM cardio_entries;") }

    /// Delete one cardio bout (History swipe-to-delete).
    @MainActor
    func deleteCardioEntry(_ id: Int64) throws {
        try db.transaction {
            let stmt = try db.prepare("DELETE FROM cardio_entries WHERE id = ?;")
            defer { stmt.finalize() }
            stmt.bind(int: id, at: 1)
            try stmt.step()
        }
    }
}
