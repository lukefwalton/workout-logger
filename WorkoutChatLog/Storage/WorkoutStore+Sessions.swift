import Foundation

/// The workout write path: the one `save`, the session lifecycle, and the
/// History edit operations. Every mutation of `workout_sessions` / `sets`
/// lives in this file.
extension WorkoutStore {
    // MARK: - The one write path (spec §2.4)

    /// Back-compat: open a fresh session and write this draft into it.
    @MainActor
    @discardableResult
    func save(_ draft: WorkoutDraft) throws -> SaveResult {
        try save(draft, into: nil)
    }

    /// Append a draft's sets to `sessionID`, or open a new session when nil.
    /// Returns the session used. The single-open discipline is the caller's
    /// (`TodayModel`): it captures the returned `sessionID` and passes it back on
    /// the next entry, so confirmed sets accrue into **one** session until the
    /// user finishes it — no longer one session per entry.
    /// Append a draft's sets to a session. The store enforces the single-open
    /// invariant here: it writes into `sessionID` only if that session is still
    /// open, otherwise it adopts the one in-progress session, and only opens a
    /// new one when none is open. So no caller — not even a stale id or a second
    /// bare `save(_:)` — can ever create a second open session. Returns the
    /// session used; `TodayModel` captures it for the active-workout banner.
    @MainActor
    @discardableResult
    func save(_ draft: WorkoutDraft, into sessionID: Int64?) throws -> SaveResult {
        try WorkoutValidator.validate(draft)        // parser generous, saver strict
        return try db.transaction {
            let targetID: Int64
            if let sessionID, try isOpenSession(sessionID) {
                targetID = sessionID
            } else if let open = try openSessionID() {
                targetID = open                      // single-open: adopt the in-progress session
            } else {
                targetID = try insertOpenSession(name: draft.name, startedAt: draft.startedAt, notes: draft.notes)
            }
            // set_index continues from MAX+1 for this session; restarting at 1
            // would collide on UNIQUE(session_id, set_index) on the second entry.
            let base = try maxSetIndex(inSession: targetID)
            // Resolve every set's exercise first (creating unknown lifts), so each
            // exercise's PRIOR history can be snapshotted *before* this entry's sets
            // land — a PR is only honest when there is earlier history to beat (§4).
            let resolved = try draft.sets.map { set in
                (exerciseID: try resolveOrCreateExercise(set.exerciseName), set: set)
            }
            var priorByExercise: [Int64: [AchievementDetector.SetFact]] = [:]
            var nameByExercise: [Int64: String] = [:]
            for id in Set(resolved.map { $0.exerciseID }) {
                priorByExercise[id] = try priorSetFacts(exerciseID: id)
                nameByExercise[id] = try exercise(id: id)?.canonicalName ?? ""
            }
            var setIDs: [Int64] = []
            var savedFacts: [AchievementDetector.SetFact] = []
            for (offset, item) in resolved.enumerated() {
                setIDs.append(try insertSet(sessionID: targetID,
                                            exerciseID: item.exerciseID,
                                            index: base + offset + 1,
                                            set: item.set))
                savedFacts.append(AchievementDetector.SetFact(exerciseID: item.exerciseID,
                                                              loadKind: item.set.loadKind,
                                                              weight: item.set.weight,
                                                              unit: item.set.unit,
                                                              reps: item.set.reps))
            }
            let achievements = AchievementDetector.achievements(saved: savedFacts,
                                                                priorByExercise: priorByExercise,
                                                                nameByExercise: nameByExercise)
            return SaveResult(sessionID: targetID, setIDs: setIDs, achievements: achievements)
        }
    }

    /// Retire the current open session if a reconciler judges it stale (older than the
    /// gap, or on a different local day), so a subsequent `save(_:into: nil)` can't
    /// adopt it and merge new sets into a forgotten workout. The Today tab reconciles
    /// through its own `@Published` path (`TodayModel.reconcileActiveSession`); this is
    /// the same guard for writers that bypass it (e.g. the OCR importer) and must run
    /// *before* their `save(_:into: nil)`. A no-op when nothing is open or the open
    /// session is still fresh.
    @MainActor
    func reconcileOpenSession(now: Date = Date(),
                             reconciler: SessionReconciler = SessionReconciler()) throws {
        guard let open = try currentOpenSession() else { return }
        if case .retire(let session) = reconciler.decide(open, now: now) {
            try finishSession(session.id, name: nil, notes: nil, feel: nil, isDeload: false)
        }
    }

    /// Open an empty session explicitly, optionally backdated to a past date.
    /// Enforces the single-open invariant: a second open session is rejected.
    /// (The usual way a session begins is lazily, via `save(_:into:)` with nil.)
    @MainActor
    @discardableResult
    func startSession(name: String? = nil, startedAt: Date = Date()) throws -> Int64 {
        try db.transaction {
            guard try openSessionID() == nil else { throw WorkoutStoreError.openSessionExists }
            return try insertOpenSession(name: name, startedAt: startedAt, notes: nil)
        }
    }

    /// Close a session: stamp `ended_at` + finish metadata. A session that never
    /// received a set is deleted instead, so an empty session can't linger.
    @MainActor
    func finishSession(_ id: Int64, endedAt: Date = Date(), name: String?,
                       notes: String?, feel: SessionFeel?, isDeload: Bool) throws {
        try db.transaction {
            if try setCount(inSession: id) == 0 {
                try deleteSessionRow(id)
            } else {
                try finishSessionRow(id, endedAt: endedAt, name: name, notes: notes, feel: feel, isDeload: isDeload)
            }
        }
    }

    // MARK: - History edits (PR 4)

    /// Delete one set. If it was the session's last set, the now-empty session is
    /// deleted too — scoped to that set's own session, so a multi-set session is
    /// left intact.
    @MainActor
    func deleteSet(_ id: Int64) throws {
        try db.transaction {
            let parent = try sessionID(ofSet: id)
            try deleteSetRow(id)
            if let parent { try deleteSessionIfEmpty(parent) }
        }
    }

    /// Delete several sets atomically — all-or-nothing in one transaction. Used
    /// by `TodayModel.undoLastSave` so a partial failure can't leave half of a
    /// just-saved entry deleted (with the undo token already consumed, the user
    /// would have no way to retry). Empty sessions are still pruned at the end.
    @MainActor
    func deleteSets(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            var parents: Set<Int64> = []
            for id in ids {
                if let parent = try sessionID(ofSet: id) { parents.insert(parent) }
                try deleteSetRow(id)
            }
            for parent in parents { try deleteSessionIfEmpty(parent) }
        }
    }

    /// Delete a whole session; its sets cascade via the FK.
    @MainActor
    func deleteSession(_ id: Int64) throws {
        try db.transaction { try deleteSessionRow(id) }
    }

    /// Edit a logged set: re-validate (reps 1…100, rir 0…10, finite weight ≥ 0) and
    /// re-resolve the exercise name through the registry (exact→alias→create), same
    /// as the save path. set_index / session / source_text are untouched. v1
    /// simplification: editing does not recompute PR/achievement detection.
    @MainActor
    func updateSet(_ id: Int64, exerciseName: String, weight: Double, unit: WeightUnit,
                   loadKind: WorkoutLoadKind, reps: Int, rir: Int?, setType: SetType, notes: String?) throws {
        // Reuse the save-path validator by shaping the edit as a one-set draft.
        try WorkoutValidator.validate(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            SetDraft(exerciseName: exerciseName, weight: weight, unit: unit, loadKind: loadKind,
                     reps: reps, rir: rir, setType: setType, notes: notes)
        ]))
        try db.transaction {
            let exerciseID = try resolveOrCreateExercise(exerciseName)
            try updateSetRow(id, exerciseID: exerciseID, weight: weight, unit: unit, loadKind: loadKind,
                             reps: reps, rir: rir, setType: setType, notes: notes)
        }
    }

    /// Edit / post-fill a session's times and metadata. started_at/ended_at change
    /// only when a value is supplied (nil keeps the stored value — started_at is
    /// NOT NULL); name/notes/feel/is_deload are set from the pre-filled form.
    /// Rejects an end earlier than the start.
    @MainActor
    func updateSession(_ id: Int64, name: String?, startedAt: Date?, endedAt: Date?,
                       notes: String?, feel: SessionFeel?, isDeload: Bool) throws {
        try db.transaction {
            let current = try sessionTimes(id)
            let effectiveStart = startedAt ?? current.started
            let effectiveEnd = endedAt ?? current.ended
            if let start = effectiveStart, let end = effectiveEnd, end < start {
                throw WorkoutStoreError.endBeforeStart
            }
            try updateSessionRow(id, name: name, startedAt: startedAt, endedAt: endedAt,
                                 notes: notes, feel: feel, isDeload: isDeload)
        }
    }

    /// The PR-comparison projection of every set logged for one exercise, across
    /// all sessions. Called inside `save` *before* the new sets are inserted, so it
    /// is exactly the prior history those sets are measured against (§4). Indexed
    /// by `exercise_id` (`idx_sets_exercise`); the canonical's own history only —
    /// never a family rollup.
    private func priorSetFacts(exerciseID: Int64) throws -> [AchievementDetector.SetFact] {
        let stmt = try db.prepare("SELECT load_kind, weight, unit, reps FROM sets WHERE exercise_id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: exerciseID, at: 1)
        var facts: [AchievementDetector.SetFact] = []
        while try stmt.step() {
            facts.append(AchievementDetector.SetFact(
                exerciseID: exerciseID,
                loadKind: WorkoutLoadKind(rawValue: stmt.text(0) ?? "") ?? .external,
                weight: stmt.optionalDouble(1),
                unit: WeightUnit(rawValue: stmt.text(2) ?? ""),
                reps: Int(stmt.int(3))))
        }
        return facts
    }

    // MARK: - Row-level writes (private; every session/set write funnels through here)

    /// Opens a session (ended_at NULL = in-progress). feel/is_deload stay unset
    /// until finish; notes/name may be carried from the first entry's draft.
    private func insertOpenSession(name: String?, startedAt: Date, notes: String?) throws -> Int64 {
        let stmt = try db.prepare("""
            INSERT INTO workout_sessions (started_at, ended_at, name, notes, feel, is_deload, created_at)
            VALUES (?, NULL, ?, ?, NULL, 0, ?);
        """)
        defer { stmt.finalize() }
        stmt.bind(text: Self.iso(startedAt), at: 1)
        stmt.bind(optionalText: name, at: 2)
        stmt.bind(optionalText: notes, at: 3)
        stmt.bind(text: Self.iso(Date()), at: 4)
        try stmt.step()
        return db.lastInsertRowID
    }

    private func maxSetIndex(inSession id: Int64) throws -> Int {
        let stmt = try db.prepare("SELECT COALESCE(MAX(set_index), 0) FROM sets WHERE session_id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        return try stmt.step() ? Int(stmt.int(0)) : 0
    }

    private func openSessionID() throws -> Int64? {
        let stmt = try db.prepare("SELECT id FROM workout_sessions WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1;")
        defer { stmt.finalize() }
        return try stmt.step() ? stmt.int(0) : nil
    }

    private func isOpenSession(_ id: Int64) throws -> Bool {
        let stmt = try db.prepare("SELECT 1 FROM workout_sessions WHERE id = ? AND ended_at IS NULL LIMIT 1;")
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        return try stmt.step()
    }

    private func sessionID(ofSet id: Int64) throws -> Int64? {
        let stmt = try db.prepare("SELECT session_id FROM sets WHERE id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        return try stmt.step() ? stmt.int(0) : nil
    }

    private func deleteSetRow(_ id: Int64) throws {
        let stmt = try db.prepare("DELETE FROM sets WHERE id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        try stmt.step()
    }

    private func deleteSessionIfEmpty(_ id: Int64) throws {
        if try setCount(inSession: id) == 0 { try deleteSessionRow(id) }
    }

    private func sessionTimes(_ id: Int64) throws -> (started: Date?, ended: Date?) {
        let stmt = try db.prepare("SELECT started_at, ended_at FROM workout_sessions WHERE id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        guard try stmt.step() else { return (nil, nil) }
        return (Self.date(stmt.text(0)), Self.date(stmt.text(1)))
    }

    private func updateSetRow(_ id: Int64, exerciseID: Int64, weight: Double, unit: WeightUnit,
                              loadKind: WorkoutLoadKind, reps: Int, rir: Int?, setType: SetType, notes: String?) throws {
        let stmt = try db.prepare("""
            UPDATE sets
            SET exercise_id = ?, weight = ?, unit = ?, load_kind = ?, reps = ?, rir = ?, set_type = ?, notes = ?
            WHERE id = ?;
        """)
        defer { stmt.finalize() }
        let load = WorkoutLoad.storedColumns(kind: loadKind, weight: weight, unit: unit)
        stmt.bind(int: exerciseID, at: 1)
        stmt.bind(optionalDouble: load.weight, at: 2)
        stmt.bind(optionalText: load.unit, at: 3)
        stmt.bind(text: loadKind.rawValue, at: 4)
        stmt.bind(int: Int64(reps), at: 5)
        stmt.bind(optionalInt: rir, at: 6)
        stmt.bind(text: setType.rawValue, at: 7)
        stmt.bind(optionalText: notes, at: 8)
        stmt.bind(int: id, at: 9)
        try stmt.step()
    }

    private func updateSessionRow(_ id: Int64, name: String?, startedAt: Date?, endedAt: Date?,
                                  notes: String?, feel: SessionFeel?, isDeload: Bool) throws {
        let stmt = try db.prepare("""
            UPDATE workout_sessions
            SET started_at = COALESCE(?, started_at), ended_at = COALESCE(?, ended_at),
                name = ?, notes = ?, feel = ?, is_deload = ?
            WHERE id = ?;
        """)
        defer { stmt.finalize() }
        stmt.bind(optionalText: startedAt.map(Self.iso), at: 1)
        stmt.bind(optionalText: endedAt.map(Self.iso), at: 2)
        stmt.bind(optionalText: name, at: 3)
        stmt.bind(optionalText: notes, at: 4)
        stmt.bind(optionalText: feel?.rawValue, at: 5)
        stmt.bind(int: Int64(isDeload ? 1 : 0), at: 6)
        stmt.bind(int: id, at: 7)
        try stmt.step()
    }

    private func deleteSessionRow(_ id: Int64) throws {
        let stmt = try db.prepare("DELETE FROM workout_sessions WHERE id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        try stmt.step()
    }

    private func finishSessionRow(_ id: Int64, endedAt: Date, name: String?, notes: String?,
                                  feel: SessionFeel?, isDeload: Bool) throws {
        // name and notes are COALESCEd so finishing without re-entering them keeps
        // what was set at open (a plan name, or the first entry's note) instead of
        // nulling it; feel/is_deload are finish-only and set outright.
        let stmt = try db.prepare("""
            UPDATE workout_sessions
            SET ended_at = ?, name = COALESCE(?, name), notes = COALESCE(?, notes), feel = ?, is_deload = ?
            WHERE id = ?;
        """)
        defer { stmt.finalize() }
        stmt.bind(text: Self.iso(endedAt), at: 1)
        stmt.bind(optionalText: name, at: 2)
        stmt.bind(optionalText: notes, at: 3)
        stmt.bind(optionalText: feel?.rawValue, at: 4)
        stmt.bind(int: Int64(isDeload ? 1 : 0), at: 5)
        stmt.bind(int: id, at: 6)
        try stmt.step()
    }

    private func insertSet(sessionID: Int64, exerciseID: Int64, index: Int, set: SetDraft) throws -> Int64 {
        let stmt = try db.prepare("""
            INSERT INTO sets
              (session_id, exercise_id, set_index, set_type, weight, unit, load_kind, reps, rir, notes, source_text, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { stmt.finalize() }
        let load = WorkoutLoad.storedColumns(kind: set.loadKind, weight: set.weight, unit: set.unit)
        stmt.bind(int: sessionID, at: 1)
        stmt.bind(int: exerciseID, at: 2)
        stmt.bind(int: Int64(index), at: 3)
        stmt.bind(text: set.setType.rawValue, at: 4)
        stmt.bind(optionalDouble: load.weight, at: 5)
        stmt.bind(optionalText: load.unit, at: 6)
        stmt.bind(text: set.loadKind.rawValue, at: 7)
        stmt.bind(int: Int64(set.reps), at: 8)
        stmt.bind(optionalInt: set.rir, at: 9)
        stmt.bind(optionalText: set.notes, at: 10)
        stmt.bind(optionalText: set.sourceText, at: 11)
        stmt.bind(text: Self.iso(Date()), at: 12)
        try stmt.step()
        return db.lastInsertRowID
    }
}
