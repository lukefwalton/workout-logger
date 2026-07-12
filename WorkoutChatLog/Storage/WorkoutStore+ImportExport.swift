import Foundation

/// The JSON backup format: full export (exercises, sessions, cardio) and the
/// merging, idempotent import (PR 13). Import writes registry/session/cardio
/// rows through raw private inserts inside one transaction — never through
/// `save`/`saveCardio`, whose own transactions would nest.
extension WorkoutStore {
    // MARK: - Export

    func dataExport(includeNotes: Bool = true, exportedAt: Date = Date()) throws -> WorkoutDataExport {
        let rows = try exportRows(includeNotes: includeNotes)
        var sessions = try exportSessions(includeNotes: includeNotes)
        for index in sessions.indices {
            sessions[index].sets = rows.filter { $0.sessionID == sessions[index].id }.map(\.set)
        }

        return WorkoutDataExport(schemaVersion: 3,   // 3: adds cardio_entries (2: sessions carry ended_at / feel / is_deload)
                                 exportedAt: Self.iso(exportedAt),
                                 app: "WorkoutChatLog",
                                 analyticsPolicy: ExportedAnalyticsPolicy(.default),
                                 exercises: try exportExercises(),
                                 sessions: sessions,
                                 cardio: try exportCardio(includeNotes: includeNotes))
    }

    func writeDataExport(includeNotes: Bool = true) throws -> URL {
        let export = try dataExport(includeNotes: includeNotes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("workout-data-\(Self.fileSafeTimestamp()).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Import (PR 13)

    /// Decode the app's own JSON export. schema_version aware by construction: v1
    /// and v2 share the exercise/set shape; v2's session ended_at/feel decode as
    /// absent/false for a v1 file (optional / defaulted fields); v3's top-level
    /// `cardio` array decodes as empty when absent (v1/v2 files).
    static func decodeExport(_ data: Data) throws -> WorkoutDataExport {
        try JSONDecoder().decode(WorkoutDataExport.self, from: data)
    }

    /// Restore an export by merging: match exercises by slug (create missing
    /// customs), then recreate each not-already-present session as a closed
    /// historical session with its sets (set_index renumbered 1…n through the same
    /// nullable-load contract as a fresh save), then add not-already-present cardio
    /// bouts. Idempotent — re-importing the same file skips sessions whose
    /// (started_at, set count, total reps) already exist and cardio bouts already
    /// present per count of (logged_at, activity, metrics). `dryRun` computes the
    /// same summary but writes nothing (one transaction, rolled back), for a
    /// pre-import preview.
    @MainActor
    func importData(_ export: WorkoutDataExport, dryRun: Bool = false) throws -> ImportSummary {
        struct DryRunComplete: Error {}
        var summary = ImportSummary()
        do {
            try db.transaction {
                var idForSlug: [String: Int64] = [:]
                var slugForExportedID: [Int64: String] = [:]
                for exercise in export.exercises {
                    slugForExportedID[exercise.id] = exercise.slug
                    if let existing = try exerciseID(slug: exercise.slug) {
                        idForSlug[exercise.slug] = existing
                    } else {
                        let newID = try insertExercise(slug: exercise.slug, canonicalName: exercise.canonicalName,
                                                       familyKey: exercise.familyKey, primaryMuscle: exercise.primaryMuscle,
                                                       secondaryMuscles: exercise.secondaryMuscles, isCustom: true)
                        for alias in exercise.aliases { try insertAlias(alias, exerciseID: newID) }
                        idForSlug[exercise.slug] = newID
                        summary.addedExercises += 1
                    }
                }
                for session in export.sessions {
                    if try importedSessionExists(session) {
                        summary.skippedSessions += 1
                        continue
                    }
                    let newSessionID = try insertImportedSession(session)
                    summary.addedSessions += 1
                    var index = 0
                    for set in session.sets.sorted(by: { $0.setIndex < $1.setIndex }) {
                        guard let slug = slugForExportedID[set.exerciseID], let exerciseID = idForSlug[slug] else { continue }
                        index += 1
                        try insertImportedSet(sessionID: newSessionID, exerciseID: exerciseID, index: index, set: set)
                        summary.addedSets += 1
                    }
                }
                // Cardio (schema_version 3; absent in v1/v2 files, decoded as []).
                // Normalized through the CardioValidator contract like a fresh save,
                // then inserted raw — never via saveCardio, whose own transaction
                // would nest inside this one. Idempotency is count-based per
                // fingerprint: each already-stored copy grants one skip, so N
                // genuinely identical bouts round-trip as N rows (a plain EXISTS
                // would collapse them) while a re-import adds none.
                var cardioSkipsLeft: [String: Int] = [:]
                for entry in export.cardio {
                    let clean = CardioValidator.normalized(CardioDraft(activity: entry.activity,
                                                                       durationSeconds: entry.durationSeconds,
                                                                       distance: entry.distance,
                                                                       distanceUnit: entry.distanceUnit,
                                                                       notes: entry.notes,
                                                                       sourceText: entry.sourceText))
                    let key = Self.cardioFingerprint(loggedAt: entry.loggedAt, clean: clean)
                    if cardioSkipsLeft[key] == nil {
                        // Snapshot the pre-import count once per fingerprint.
                        cardioSkipsLeft[key] = try importedCardioCount(loggedAt: entry.loggedAt, clean: clean)
                    }
                    if let remaining = cardioSkipsLeft[key], remaining > 0 {
                        cardioSkipsLeft[key] = remaining - 1
                        summary.skippedCardio += 1
                    } else {
                        try insertImportedCardio(entry, clean: clean)
                        summary.addedCardio += 1
                    }
                }
                if dryRun { throw DryRunComplete() }
            }
        } catch is DryRunComplete {
            // intended: summary computed, transaction rolled back, nothing persisted
        }
        return summary
    }

    /// Read + decode + import a file (used by Settings). `dryRun` previews.
    @MainActor
    func importData(fromFileAt url: URL, dryRun: Bool = false) throws -> ImportSummary {
        try importData(Self.decodeExport(Data(contentsOf: url)), dryRun: dryRun)
    }

    // MARK: - Import inserts (private; raw rows inside the ambient import transaction)

    /// Idempotency for import: a session counts as already present if one with the
    /// same started_at has the same set count and total reps (a cheap fingerprint).
    private func importedSessionExists(_ session: ExportedSession) throws -> Bool {
        let importedCount = session.sets.count
        let importedReps = session.sets.reduce(0) { $0 + $1.reps }
        let stmt = try db.prepare("""
            SELECT COUNT(st.id), COALESCE(SUM(st.reps), 0)
            FROM workout_sessions s LEFT JOIN sets st ON st.session_id = s.id
            WHERE s.started_at = ?
            GROUP BY s.id;
        """)
        defer { stmt.finalize() }
        stmt.bind(text: session.startedAt, at: 1)
        while try stmt.step() {
            if Int(stmt.int(0)) == importedCount && Int(stmt.int(1)) == importedReps { return true }
        }
        return false
    }

    /// Restore a session as a closed historical record (ended_at falls back to
    /// started_at if the export had none), so it never trips the single-open index.
    private func insertImportedSession(_ session: ExportedSession) throws -> Int64 {
        let stmt = try db.prepare("""
            INSERT INTO workout_sessions (started_at, ended_at, name, notes, feel, is_deload, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        """)
        defer { stmt.finalize() }
        stmt.bind(text: session.startedAt, at: 1)
        stmt.bind(text: session.endedAt ?? session.startedAt, at: 2)
        stmt.bind(optionalText: session.name, at: 3)
        stmt.bind(optionalText: session.notes, at: 4)
        stmt.bind(optionalText: session.feel, at: 5)
        stmt.bind(int: Int64(session.isDeload ? 1 : 0), at: 6)
        stmt.bind(text: session.createdAt.isEmpty ? Self.iso(Date()) : session.createdAt, at: 7)
        try stmt.step()
        return db.lastInsertRowID
    }

    private func insertImportedSet(sessionID: Int64, exerciseID: Int64, index: Int, set: ExportedSet) throws {
        let stmt = try db.prepare("""
            INSERT INTO sets
              (session_id, exercise_id, set_index, set_type, weight, unit, load_kind, reps, rir, notes, source_text, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { stmt.finalize() }
        stmt.bind(int: sessionID, at: 1)
        stmt.bind(int: exerciseID, at: 2)
        stmt.bind(int: Int64(index), at: 3)
        stmt.bind(text: set.setType, at: 4)
        stmt.bind(optionalDouble: set.load.amount, at: 5)        // already nil for loadless (WorkoutLoad.stored)
        stmt.bind(optionalText: set.load.unit?.rawValue, at: 6)
        stmt.bind(text: set.load.kind.rawValue, at: 7)
        stmt.bind(int: Int64(set.reps), at: 8)
        stmt.bind(optionalInt: set.rir, at: 9)
        stmt.bind(optionalText: set.notes, at: 10)
        stmt.bind(optionalText: set.sourceText, at: 11)
        stmt.bind(text: set.createdAt.isEmpty ? Self.iso(Date()) : set.createdAt, at: 12)
        try stmt.step()
    }

    /// The cardio idempotency fingerprint, over the *normalized* metric fields
    /// (what actually lands in the table) plus the verbatim logged_at string.
    /// `notes` and `source_text` are deliberately excluded: a notes-excluded
    /// export must stay idempotent against a store that has the same bouts with
    /// notes (and vice versa) — same time + activity + metrics is "the same
    /// bout", regardless of prose. Joined on the unit-separator control
    /// character so a free-text activity (or a hand-edited timestamp) containing
    /// a printable delimiter can't collide two distinct bouts into one key.
    private static func cardioFingerprint(loggedAt: String, clean: CardioDraft) -> String {
        let parts: [String] = [
            loggedAt,
            clean.activity,
            clean.durationSeconds.map { String($0) } ?? "∅",
            clean.distance.map { String($0) } ?? "∅",
            clean.distanceUnit?.rawValue ?? "∅",
        ]
        return parts.joined(separator: "\u{1F}")
    }

    /// How many stored bouts already match an imported bout's fingerprint. `IS ?`
    /// (not `=`) so a NULL metric matches a NULL column.
    private func importedCardioCount(loggedAt: String, clean: CardioDraft) throws -> Int {
        let stmt = try db.prepare("""
            SELECT COUNT(*) FROM cardio_entries
            WHERE logged_at = ? AND activity = ?
              AND duration_seconds IS ? AND distance IS ? AND distance_unit IS ?;
        """)
        defer { stmt.finalize() }
        stmt.bind(text: loggedAt, at: 1)
        stmt.bind(text: clean.activity, at: 2)
        stmt.bind(optionalInt: clean.durationSeconds, at: 3)
        stmt.bind(optionalDouble: clean.distance, at: 4)
        stmt.bind(optionalText: clean.distanceUnit?.rawValue, at: 5)
        return try stmt.step() ? Int(stmt.int(0)) : 0
    }

    /// Raw insert for an imported cardio bout, inside the ambient import
    /// transaction (never `saveCardio`, whose own transaction would nest).
    /// Normalized metrics, verbatim timestamps — same contract as
    /// `insertImportedSession`.
    private func insertImportedCardio(_ entry: ExportedCardioEntry, clean: CardioDraft) throws {
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
        stmt.bind(text: entry.loggedAt, at: 7)
        stmt.bind(text: entry.createdAt.isEmpty ? Self.iso(Date()) : entry.createdAt, at: 8)
        try stmt.step()
    }

    // MARK: - Export rows (private)

    private func exportExercises() throws -> [ExportedExercise] {
        let aliasMap = try aliasesByExercise()
        let stmt = try db.prepare("""
            SELECT id, slug, canonical_name, family_key, primary_muscle, secondary_muscles, is_custom, created_at
            FROM exercises
            ORDER BY canonical_name COLLATE NOCASE;
        """)
        defer { stmt.finalize() }

        var rows: [ExportedExercise] = []
        while try stmt.step() {
            let id = stmt.int(0)
            rows.append(ExportedExercise(id: id,
                                         slug: stmt.text(1) ?? "",
                                         canonicalName: stmt.text(2) ?? "",
                                         familyKey: stmt.text(3),
                                         primaryMuscle: stmt.text(4),
                                         secondaryMuscles: Self.decodeStringArray(stmt.text(5)),
                                         isCustom: stmt.int(6) != 0,
                                         aliases: aliasMap[id] ?? [],
                                         createdAt: stmt.text(7) ?? ""))
        }
        return rows
    }

    private func exportSessions(includeNotes: Bool) throws -> [ExportedSession] {
        let stmt = try db.prepare("""
            SELECT id, started_at, ended_at, name, notes, feel, is_deload, created_at
            FROM workout_sessions
            ORDER BY started_at ASC, id ASC;
        """)
        defer { stmt.finalize() }

        var rows: [ExportedSession] = []
        while try stmt.step() {
            rows.append(ExportedSession(id: stmt.int(0),
                                        startedAt: stmt.text(1) ?? "",
                                        endedAt: stmt.text(2),
                                        name: stmt.text(3),
                                        notes: includeNotes ? stmt.text(4) : nil,
                                        feel: stmt.text(5),
                                        isDeload: stmt.int(6) != 0,
                                        createdAt: stmt.text(7) ?? "",
                                        sets: []))
        }
        return rows
    }

    /// Cardio bouts for the JSON export, oldest first for a stable file. Timestamps
    /// are exported as the stored strings verbatim (like sessions/sets) so a
    /// round-trip is byte-for-byte; notes honor the same privacy toggle.
    private func exportCardio(includeNotes: Bool) throws -> [ExportedCardioEntry] {
        let stmt = try db.prepare("""
            SELECT id, activity, duration_seconds, distance, distance_unit, notes, source_text, logged_at, created_at
            FROM cardio_entries
            ORDER BY logged_at ASC, id ASC;
        """)
        defer { stmt.finalize() }

        var rows: [ExportedCardioEntry] = []
        while try stmt.step() {
            rows.append(ExportedCardioEntry(id: stmt.int(0),
                                            activity: stmt.text(1) ?? CardioActivity.generic.display,
                                            durationSeconds: stmt.optionalInt(2),
                                            distance: stmt.optionalDouble(3),
                                            distanceUnit: stmt.text(4).flatMap(CardioDistanceUnit.init(rawValue:)),
                                            notes: includeNotes ? stmt.text(5) : nil,
                                            sourceText: stmt.text(6),
                                            loggedAt: stmt.text(7) ?? "",
                                            createdAt: stmt.text(8) ?? ""))
        }
        return rows
    }

    private struct ExportRow {
        let sessionID: Int64
        let set: ExportedSet
    }

    private func exportRows(includeNotes: Bool) throws -> [ExportRow] {
        let stmt = try db.prepare("""
            SELECT
                s.session_id, s.id, s.exercise_id, e.canonical_name, s.set_index,
                s.set_type, s.weight, s.unit, s.load_kind, s.reps, s.rir, s.notes, s.source_text, s.created_at
            FROM sets s
            JOIN exercises e ON e.id = s.exercise_id
            ORDER BY s.session_id ASC, s.set_index ASC;
        """)
        defer { stmt.finalize() }

        var rows: [ExportRow] = []
        while try stmt.step() {
            let unit = WeightUnit(rawValue: stmt.text(7) ?? "") ?? .lb
            let loadKind = WorkoutLoadKind(rawValue: stmt.text(8) ?? "") ?? .external
            let sourceText = stmt.text(12)
            rows.append(ExportRow(sessionID: stmt.int(0),
                                  set: ExportedSet(id: stmt.int(1),
                                                   exerciseID: stmt.int(2),
                                                   exerciseName: stmt.text(3) ?? "",
                                                   setIndex: Int(stmt.int(4)),
                                                   setType: stmt.text(5) ?? "working",
                                                   load: WorkoutLoad.stored(kind: loadKind,
                                                                            weight: stmt.double(6),
                                                                            unit: unit),
                                                   reps: Int(stmt.int(9)),
                                                   rir: stmt.optionalInt(10),
                                                   notes: includeNotes ? stmt.text(11) : nil,
                                                   sourceText: sourceText,
                                                   createdAt: stmt.text(13) ?? "")))
        }
        return rows
    }

    private static func fileSafeTimestamp(_ date: Date = Date()) -> String {
        iso(date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "Z", with: "UTC")
    }
}
