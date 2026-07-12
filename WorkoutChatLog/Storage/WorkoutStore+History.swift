import Foundation

/// Non-isolated set/session reads: counts, the open-session snapshot, the
/// "last time" hint, and the joined history projection behind History,
/// Progress, and the AI share prompt. Nothing in this file writes.
extension WorkoutStore {
    // MARK: - Reads (UI counts, the future audit view, and tests)

    func sessionCount() throws -> Int { try count(inTable: "workout_sessions") }
    func setCount() throws -> Int { try count(inTable: "sets") }

    func setCount(inSession id: Int64) throws -> Int {
        try db.readTransaction {
            let stmt = try db.prepare("SELECT COUNT(*) FROM sets WHERE session_id = ?;")
            defer { stmt.finalize() }
            stmt.bind(int: id, at: 1)
            return try stmt.step() ? Int(stmt.int(0)) : 0
        }
    }

    /// Per-session set-time span in seconds (MAX − MIN of `created_at`), for the
    /// calorie estimate's set-span duration fallback (PR 11). A single-set session
    /// yields 0 (the estimator applies its own small fallback). One query, keyed by
    /// session id. Non-isolated read. `created_at` is the store's fixed ISO8601, so
    /// MIN/MAX over the text equals the chronological min/max.
    func sessionSetSpans() throws -> [Int64: Double] {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT session_id, MIN(created_at), MAX(created_at)
                FROM sets GROUP BY session_id;
            """)
            defer { stmt.finalize() }
            var out: [Int64: Double] = [:]
            while try stmt.step() {
                guard let earliest = Self.date(stmt.text(1)),
                      let latest = Self.date(stmt.text(2)) else { continue }
                out[stmt.int(0)] = max(0, latest.timeIntervalSince(earliest))
            }
            return out
        }
    }

    /// Snapshot of the one in-progress session (ended_at IS NULL), or nil. A
    /// non-isolated read so the widget's separate process (PR 12) can call it.
    func currentOpenSession() throws -> OpenSession? {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT s.id, s.started_at, s.name,
                       (SELECT MAX(created_at) FROM sets WHERE session_id = s.id),
                       (SELECT COUNT(*) FROM sets WHERE session_id = s.id)
                FROM workout_sessions s
                WHERE s.ended_at IS NULL
                ORDER BY s.id DESC
                LIMIT 1;
            """)
            defer { stmt.finalize() }
            guard try stmt.step() else { return nil }
            return OpenSession(id: stmt.int(0),
                               startedAt: Self.date(stmt.text(1)) ?? Date(),
                               lastSetAt: Self.date(stmt.text(3)),
                               name: stmt.text(2),
                               setCount: Int(stmt.int(4)))
        }
    }

    /// The "last time" hint (§4): the sets this exercise was logged with in its
    /// most recent **finished** session, or nil if it has none. A non-isolated read.
    /// The open (in-progress) session is excluded so "last time" always means a
    /// genuinely prior workout, never the one being added to right now. Canonical-
    /// only — keyed by `exercise_id`, so it never blends a different lift's history.
    /// Validated against the v1 schema in sqlite3 (open-excluded, most-recent-closed,
    /// skips sessions lacking the exercise; uses `idx_sets_exercise`).
    func lastTime(forExercise exerciseID: Int64) throws -> LastTime? {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT s.weight, s.unit, s.load_kind, s.reps, ws.started_at
                FROM sets s
                JOIN workout_sessions ws ON ws.id = s.session_id
                WHERE s.exercise_id = ?1
                  AND ws.ended_at IS NOT NULL
                  AND ws.id = (
                    SELECT ws2.id FROM workout_sessions ws2
                    JOIN sets s2 ON s2.session_id = ws2.id
                    WHERE s2.exercise_id = ?1 AND ws2.ended_at IS NOT NULL
                    ORDER BY ws2.started_at DESC, ws2.id DESC
                    LIMIT 1)
                ORDER BY s.set_index ASC;
            """)
            defer { stmt.finalize() }
            stmt.bind(int: exerciseID, at: 1)
            var sets: [LastTimeSet] = []
            var startedAt: Date?
            while try stmt.step() {
                // Reconstruct the load honestly from the *stored* kind + nullable columns,
                // exactly like `priorSetFacts`: a NULL weight/unit stays nil rather than
                // being invented as "0 lb / external", so a bodyweight or unspecified set
                // round-trips as itself (honest-or-nothing).
                let loadKind = WorkoutLoadKind(rawValue: stmt.text(2) ?? "") ?? .external
                let load = WorkoutLoad(kind: loadKind,
                                       amount: stmt.optionalDouble(0),
                                       unit: stmt.text(1).flatMap(WeightUnit.init(rawValue:)))
                sets.append(LastTimeSet(load: load, reps: Int(stmt.int(3))))
                if startedAt == nil { startedAt = Self.date(stmt.text(4)) }
            }
            guard let startedAt, !sets.isEmpty else { return nil }
            return LastTime(startedAt: startedAt, sets: sets)
        }
    }

    /// A session's sets in stored order — the backbone of the future audit view
    /// and a convenient assertion target for tests.
    func sets(inSession sessionID: Int64) throws -> [StoredSet] {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT id, exercise_id, set_index, set_type, weight, unit, load_kind, reps, rir, notes, source_text
                FROM sets WHERE session_id = ? ORDER BY set_index;
            """)
            defer { stmt.finalize() }
            stmt.bind(int: sessionID, at: 1)
            var rows: [StoredSet] = []
            while try stmt.step() {
                rows.append(StoredSet(id: stmt.int(0),
                                      exerciseID: stmt.int(1),
                                      setIndex: Int(stmt.int(2)),
                                      setType: stmt.text(3) ?? "working",
                                      weight: stmt.double(4),
                                      unit: stmt.text(5) ?? "lb",
                                      loadKind: stmt.text(6) ?? WorkoutLoadKind.external.rawValue,
                                      reps: Int(stmt.int(7)),
                                      rir: stmt.optionalInt(8),
                                      notes: stmt.text(9),
                                      sourceText: stmt.text(10)))
            }
            return rows
        }
    }

    func setHistory(since startDate: Date? = nil, includeNotes: Bool = false) throws -> [WorkoutSetHistoryRow] {
        let start = startDate.map(Self.iso)
        return try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT
                    ws.id, ws.name, ws.notes, ws.started_at, ws.ended_at, ws.feel, ws.is_deload,
                    s.id, s.exercise_id, e.canonical_name, s.set_index, s.set_type,
                    s.weight, s.unit, s.load_kind, s.reps, s.rir, s.notes, s.source_text, e.primary_muscle
                FROM sets s
                JOIN workout_sessions ws ON ws.id = s.session_id
                JOIN exercises e ON e.id = s.exercise_id
                WHERE (? IS NULL OR ws.started_at >= ?)
                ORDER BY ws.started_at DESC, ws.id DESC, s.set_index ASC;
            """)
            defer { stmt.finalize() }
            stmt.bind(optionalText: start, at: 1)
            stmt.bind(optionalText: start, at: 2)

            var rows: [WorkoutSetHistoryRow] = []
            while try stmt.step() {
                let unit = WeightUnit(rawValue: stmt.text(13) ?? "") ?? .lb
                let loadKind = WorkoutLoadKind(rawValue: stmt.text(14) ?? "") ?? .external
                rows.append(WorkoutSetHistoryRow(sessionID: stmt.int(0),
                                                 sessionName: stmt.text(1),
                                                 sessionNotes: includeNotes ? stmt.text(2) : nil,
                                                 startedAt: stmt.text(3) ?? "",
                                                 sessionEndedAt: stmt.text(4),
                                                 sessionFeel: SessionFeel(rawValue: stmt.text(5) ?? ""),
                                                 sessionIsDeload: stmt.int(6) != 0,
                                                 setID: stmt.int(7),
                                                 exerciseID: stmt.int(8),
                                                 exerciseName: stmt.text(9) ?? "",
                                                 setIndex: Int(stmt.int(10)),
                                                 setType: SetType(rawValue: stmt.text(11) ?? "") ?? .working,
                                                 load: WorkoutLoad.stored(kind: loadKind,
                                                                          weight: stmt.double(12),
                                                                          unit: unit),
                                                 reps: Int(stmt.int(15)),
                                                 rir: stmt.optionalInt(16),
                                                 notes: includeNotes ? stmt.text(17) : nil,
                                                 sourceText: stmt.text(18),
                                                 primaryMuscle: stmt.text(19)))
            }
            return rows
        }
    }

    func aiSharePrompt(lastDays days: Int = 30,
                       includeNotes: Bool = false,
                       includeTrends: Bool = false) throws -> String {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        return WorkoutShareSummary.aiPrompt(rows: try setHistory(since: start, includeNotes: includeNotes),
                                            days: days,
                                            includeNotes: includeNotes,
                                            includeTrends: includeTrends)
    }
}
