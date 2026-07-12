import Foundation

/// Daily supplement tracking (schema v2): the preset seed, the configured list,
/// intake reads, and the one intake write path. Every write to `supplements` /
/// `supplement_intake` lives in this file.
extension WorkoutStore {
    // MARK: - Supplements (daily tracking, schema v2)

    /// Preset supplements seeded on first run. Creatine is a plain checkbox; Protein
    /// tracks optional grams.
    static let presetSupplements: [(name: String, tracksGrams: Bool)] = [
        ("Creatine", false),
        ("Protein", true),
    ]

    /// Insert the presets once — idempotent (only when the table is empty), so
    /// calling it on every launch (like the exercise seed) is safe.
    @MainActor
    func seedSupplementsIfNeeded() throws {
        try db.transaction {
            guard try count(inTable: "supplements") == 0 else { return }
            for (index, preset) in Self.presetSupplements.enumerated() {
                try insertSupplementRow(name: preset.name, isPreset: true,
                                        tracksGrams: preset.tracksGrams, sortOrder: index)
            }
        }
    }

    /// The configured supplements, presets first. Non-isolated read.
    func supplements() throws -> [Supplement] {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT id, name, is_preset, tracks_grams, sort_order
                FROM supplements ORDER BY sort_order ASC, id ASC;
            """)
            defer { stmt.finalize() }
            var out: [Supplement] = []
            while try stmt.step() {
                out.append(Supplement(id: stmt.int(0),
                                      name: stmt.text(1) ?? "",
                                      isPreset: stmt.int(2) == 1,
                                      tracksGrams: stmt.int(3) == 1,
                                      sortOrder: Int(stmt.int(4))))
            }
            return out
        }
    }

    /// One day's intake keyed by supplement id (presence = taken). Non-isolated.
    func supplementIntake(onDay day: String) throws -> [Int64: SupplementIntake] {
        try db.readTransaction {
            let stmt = try db.prepare("SELECT supplement_id, day, grams FROM supplement_intake WHERE day = ?;")
            defer { stmt.finalize() }
            stmt.bind(text: day, at: 1)
            var out: [Int64: SupplementIntake] = [:]
            while try stmt.step() {
                let sid = stmt.int(0)
                out[sid] = SupplementIntake(supplementID: sid, day: stmt.text(1) ?? day, grams: stmt.optionalDouble(2))
            }
            return out
        }
    }

    /// All intake on/after `sinceDay` ('YYYY-MM-DD'), oldest first — the raw history
    /// the trends analytics aggregates. Non-isolated read.
    func supplementHistory(sinceDay: String) throws -> [SupplementIntake] {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT supplement_id, day, grams FROM supplement_intake
                WHERE day >= ? ORDER BY day ASC, supplement_id ASC;
            """)
            defer { stmt.finalize() }
            stmt.bind(text: sinceDay, at: 1)
            var out: [SupplementIntake] = []
            while try stmt.step() {
                out.append(SupplementIntake(supplementID: stmt.int(0), day: stmt.text(1) ?? "", grams: stmt.optionalDouble(2)))
            }
            return out
        }
    }

    /// Add a custom supplement (always a checkbox; grams stays a Protein thing for
    /// now). No-ops on blank or a case-insensitive duplicate name; returns the new id
    /// or nil when skipped. Sorted after everything else.
    @MainActor
    @discardableResult
    func addSupplement(named rawName: String) throws -> Int64? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return try db.transaction {
            let existing = try supplements()
            guard !existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return nil
            }
            let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
            return try insertSupplementRow(name: name, isPreset: false, tracksGrams: false, sortOrder: nextOrder)
        }
    }

    /// Remove a custom supplement (presets can't be removed); its intake cascades.
    @MainActor
    func removeSupplement(_ id: Int64) throws {
        try db.transaction {
            let stmt = try db.prepare("DELETE FROM supplements WHERE id = ? AND is_preset = 0;")
            defer { stmt.finalize() }
            stmt.bind(int: id, at: 1)
            try stmt.step()
        }
    }

    /// Set a supplement's intake for a day: `taken == false` deletes the row;
    /// `taken == true` upserts (presence = taken), storing optional `grams`. One write
    /// path for toggling and for editing grams.
    @MainActor
    func setSupplementIntake(supplementID: Int64, day: String, taken: Bool, grams: Double? = nil) throws {
        try db.transaction {
            if taken {
                let stmt = try db.prepare("""
                    INSERT INTO supplement_intake (supplement_id, day, grams, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(supplement_id, day) DO UPDATE SET grams = excluded.grams;
                """)
                defer { stmt.finalize() }
                stmt.bind(int: supplementID, at: 1)
                stmt.bind(text: day, at: 2)
                stmt.bind(optionalDouble: grams.map { max(0, $0) }, at: 3)
                stmt.bind(text: Self.iso(Date()), at: 4)
                try stmt.step()
            } else {
                let stmt = try db.prepare("DELETE FROM supplement_intake WHERE supplement_id = ? AND day = ?;")
                defer { stmt.finalize() }
                stmt.bind(int: supplementID, at: 1)
                stmt.bind(text: day, at: 2)
                try stmt.step()
            }
        }
    }

    @discardableResult
    private func insertSupplementRow(name: String, isPreset: Bool, tracksGrams: Bool, sortOrder: Int) throws -> Int64 {
        let stmt = try db.prepare("""
            INSERT INTO supplements (name, is_preset, tracks_grams, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?);
        """)
        defer { stmt.finalize() }
        stmt.bind(text: name, at: 1)
        stmt.bind(int: Int64(isPreset ? 1 : 0), at: 2)
        stmt.bind(int: Int64(tracksGrams ? 1 : 0), at: 3)
        stmt.bind(int: Int64(sortOrder), at: 4)
        stmt.bind(text: Self.iso(Date()), at: 5)
        try stmt.step()
        return db.lastInsertRowID
    }
}
