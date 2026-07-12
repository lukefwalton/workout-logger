import Foundation

/// The exercise registry: seeding, name normalization, the resolution stack
/// (exact → alias → loose → fuzzy proposals), and the Settings management
/// surface (add / rename / merge / delete). Every write to `exercises` /
/// `exercise_aliases` lives in this file.
extension WorkoutStore {
    // MARK: - Seeding

    /// Upserts the canonical library, keyed on the stable `slug` (§2b). A brand
    /// new slug is inserted; an existing slug keeps the row (and the user's
    /// possibly-renamed `canonical_name`) while refreshing seed-owned metadata
    /// (family/muscles) and re-adding any missing aliases. That makes a
    /// post-launch seed expansion non-destructive, and makes calling this on
    /// every launch idempotent — the count only grows when the seed itself does.
    @MainActor
    func seedExercisesIfNeeded(_ seeds: [SeedExercise]) throws {
        try db.transaction {
            for seed in seeds {
                let id: Int64
                if let existing = try exerciseID(slug: seed.slug) {
                    try updateSeedMetadata(existing,
                                           familyKey: seed.familyKey,
                                           primaryMuscle: seed.primaryMuscle,
                                           secondaryMuscles: seed.secondaryMuscles)
                    id = existing
                } else {
                    id = try insertExercise(slug: seed.slug,
                                            canonicalName: seed.canonicalName,
                                            familyKey: seed.familyKey,
                                            primaryMuscle: seed.primaryMuscle,
                                            secondaryMuscles: seed.secondaryMuscles,
                                            isCustom: false)
                }
                for alias in seed.aliases { try insertAlias(alias, exerciseID: id) }
            }
        }
    }

    /// User-facing registry writer for adding a lift before it appears in a log.
    /// Unknown exercises can still be created by `save`, but Settings needs this
    /// explicit path so users can prepare their library without logging a dummy set.
    @MainActor
    @discardableResult
    func addExercise(named rawName: String) throws -> Int64 {
        let name = Self.normalizeName(rawName)
        guard !name.isEmpty else { throw ParseError.emptyExerciseName }
        if let existing = try resolveExercise(name) { return existing }
        return try db.transaction {
            try insertExercise(slug: try uniqueSlug(forName: name),
                               canonicalName: name,
                               familyKey: nil,
                               primaryMuscle: nil,
                               secondaryMuscles: [],
                               isCustom: true)
        }
    }

    // MARK: - Exercise library management (PR 9)

    /// Library entries with usage counts, for Settings → Exercises.
    func managedExercises() throws -> [ManagedExercise] {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT e.id, e.canonical_name, e.family_key, e.primary_muscle, e.is_custom,
                       (SELECT COUNT(*) FROM sets WHERE exercise_id = e.id)
                FROM exercises e
                ORDER BY e.canonical_name COLLATE NOCASE;
            """)
            defer { stmt.finalize() }
            var rows: [ManagedExercise] = []
            while try stmt.step() {
                rows.append(ManagedExercise(id: stmt.int(0),
                                            canonicalName: stmt.text(1) ?? "",
                                            familyKey: stmt.text(2),
                                            primaryMuscle: stmt.text(3),
                                            isCustom: stmt.int(4) != 0,
                                            usageCount: Int(stmt.int(5))))
            }
            return rows
        }
    }

    /// Rename the display name only — `id` and `slug` are unchanged, so every
    /// logged set keeps pointing at the same identity and history is untouched.
    /// Renaming onto another exercise's display name is rejected (a merge was
    /// likely meant).
    @MainActor
    func renameExercise(_ id: Int64, to newName: String) throws {
        let name = Self.normalizeName(newName)
        guard !name.isEmpty else { throw ParseError.emptyExerciseName }
        try db.transaction {
            if let existing = try exerciseID(canonicalNameMatching: name), existing != id {
                throw WorkoutStoreError.renameCollision(name)
            }
            try updateCanonicalName(id, to: name)
        }
    }

    /// Merge `source` into `target` in one transaction: re-point every set, fold
    /// source's aliases into target, add source's old name as an alias of target,
    /// then delete source. Target ends up owning the combined history so charts
    /// stay intact. For duplicates only — the UI must warn it's not for variations.
    @MainActor
    func mergeExercise(from sourceID: Int64, into targetID: Int64) throws {
        guard sourceID != targetID else { throw WorkoutStoreError.selfMerge }
        try db.transaction {
            guard let source = try exercise(id: sourceID), (try exercise(id: targetID)) != nil else { return }
            try repointSets(from: sourceID, to: targetID)
            try repointAliases(from: sourceID, to: targetID)
            try insertAlias(source.canonicalName, exerciseID: targetID)   // normalized + OR IGNORE keeps any existing owner
            try deleteExerciseRow(sourceID)
        }
    }

    /// Delete a user-created exercise, only when no set references it — never
    /// orphan logged data. Seeded lifts aren't deletable (rename or merge instead).
    @MainActor
    func deleteExercise(_ id: Int64) throws {
        try db.transaction {
            guard let info = try customAndUsage(id) else { return }
            guard info.isCustom else { throw WorkoutStoreError.cannotDeleteSeeded }
            guard info.used == 0 else { throw WorkoutStoreError.exerciseInUse(info.used) }
            try deleteExerciseRow(id)
        }
    }

    // MARK: - Resolution (§1.1)

    /// Non-mutating lookup: exact canonical (case-insensitive) -> alias -> nil.
    /// Safe to call from anywhere (a future confirm-card preview or quick-log)
    /// because it never writes. Track 3's embedding nearest-neighbor slots in
    /// between the alias step and `nil`. Rejects blank input so callers can't
    /// pretend whitespace is a real lift.
    func resolveExercise(_ rawName: String) throws -> Int64? {
        let name = Self.normalizeName(rawName)
        guard !name.isEmpty else { throw ParseError.emptyExerciseName }
        return try db.readTransaction {
            if let id = try exerciseID(canonicalNameMatching: name) { return id }
            if let id = try exerciseID(aliasMatching: name) { return id }
            // Layer 1.5: punctuation/plural-insensitive join. The seed can't list
            // every spacing/plural variant ("chin ups" alongside "chin up"/"chinup"),
            // and a missing one used to spawn a duplicate custom on save. This folds
            // them onto the existing canonical without inventing a fuzzy match: whole
            // strings must agree once non-alphanumerics and a trailing plural are
            // stripped, so distinct lifts never collapse. Abbreviations still fall
            // through to the fuzzy/semantic *proposals* (the confirm card's "Did you
            // mean…"), which the user confirms.
            return try exerciseID(looseMatching: name)
        }
    }

    /// A spacing/punctuation/plural-insensitive key for exercise joining:
    /// lowercased, non-alphanumerics removed, one trailing plural `s` dropped
    /// (guarded so short words like "abs" aren't mangled). "Chin-Up", "chin up",
    /// and "chin ups" all map to "chinup". Applied to both sides of a comparison,
    /// so equality stays meaningful.
    static func looseKey(_ raw: String) -> String {
        var key = String(raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        if key.count > 3, key.hasSuffix("s") { key.removeLast() }
        return key
    }

    /// Resolve by loose key against canonical names first, then aliases. O(library
    /// size); the registry is small (≈90 seeded + customs) and this only runs when
    /// exact + alias both miss.
    private func exerciseID(looseMatching rawName: String) throws -> Int64? {
        let key = Self.looseKey(rawName)
        guard !key.isEmpty else { return nil }
        let canon = try db.prepare("SELECT id, canonical_name FROM exercises;")
        defer { canon.finalize() }
        while try canon.step() {
            if Self.looseKey(canon.text(1) ?? "") == key { return canon.int(0) }
        }
        let aliases = try db.prepare("SELECT exercise_id, alias FROM exercise_aliases;")
        defer { aliases.finalize() }
        while try aliases.step() {
            if Self.looseKey(aliases.text(1) ?? "") == key { return aliases.int(0) }
        }
        return nil
    }

    /// Layer 2 (fuzzy) of the resolution stack (§1.1): ranked candidate canonicals
    /// for an unrecognized query. Non-mutating — it *proposes*; the caller offers
    /// them and the user confirms. Meant to be consulted only when exact + alias
    /// both miss, so an aliased lift ("rdl" → Romanian Deadlift) is never
    /// "corrected" onto a different lift. The generous threshold is safe precisely
    /// because nothing here auto-applies.
    func suggestExercisesFuzzy(for raw: String, limit: Int = 3) throws -> [ExerciseSuggestion] {
        let query = Self.normalizeName(raw)
        guard !query.isEmpty else { return [] }
        let hits: [ExerciseSuggestion] = try db.readTransaction {
            let aliasMap = try aliasesByExercise()
            let stmt = try db.prepare("SELECT id, canonical_name, family_key FROM exercises;")
            defer { stmt.finalize() }
            var found: [ExerciseSuggestion] = []
            while try stmt.step() {
                let id = stmt.int(0)
                let name = stmt.text(1) ?? ""
                let candidates = [name] + (aliasMap[id] ?? [])
                let best = candidates.map { FuzzyMatch.similarity(query, $0) }.max() ?? 0
                if best >= Self.fuzzySuggestionThreshold {
                    found.append(ExerciseSuggestion(exerciseID: id, canonicalName: name,
                                                    familyKey: stmt.text(2), score: best, via: .fuzzy))
                }
            }
            return found
        }
        let queryLength = query.count
        return Array(hits.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let d0 = abs($0.canonicalName.count - queryLength), d1 = abs($1.canonicalName.count - queryLength)
            if d0 != d1 { return d0 < d1 }   // prefer the closest-length name (Bench Press before Incline Bench Press)
            return $0.canonicalName < $1.canonicalName
        }.prefix(limit))
    }

    /// Calibrated to the Jaro-Winkler + token metric so real typos surface
    /// ("dops" → Dip ≈ 0.85) while garbage ("asdfqwer") stays below it.
    static let fuzzySuggestionThreshold = 0.78

    /// Below this fuzzy confidence, the optional semantic layer (Layer 3, §1.1) may
    /// also be consulted. The spec's ~0.85; confirm against the live metric on device
    /// (the fuzzy threshold itself was recalibrated to 0.78 — see learnings/010).
    static let semanticEscalationThreshold = 0.85

    /// The canonical registry as (id, name, family) triples — the input the optional
    /// semantic layer embeds and caches once (PR 7). A non-isolated read; it never
    /// writes and carries no `NaturalLanguage` symbol, so the gated matcher stays
    /// isolated. Ordered by id for a stable cache.
    func exerciseCanonicals() throws -> [(id: Int64, name: String, familyKey: String?)] {
        try db.readTransaction {
            let stmt = try db.prepare("SELECT id, canonical_name, family_key FROM exercises ORDER BY id;")
            defer { stmt.finalize() }
            var rows: [(id: Int64, name: String, familyKey: String?)] = []
            while try stmt.step() {
                rows.append((id: stmt.int(0), name: stmt.text(1) ?? "", familyKey: stmt.text(2)))
            }
            return rows
        }
    }

    /// Resolve, creating a new muscle-less, user-correctable exercise when the
    /// name is unknown. Store-internal on purpose: creating a permanent
    /// `exercises` row only ever happens inside the save/updateSet transactions
    /// (`WorkoutStore+Sessions.swift`), so the single write path stays enforced
    /// by the store rather than by feature-code convention. The future editable-
    /// registry surface will be the one other, intentional writer.
    @discardableResult
    func resolveOrCreateExercise(_ rawName: String) throws -> Int64 {
        if let id = try resolveExercise(rawName) { return id }
        let name = Self.normalizeName(rawName)
        return try insertExercise(slug: try uniqueSlug(forName: name),
                                  canonicalName: name,
                                  familyKey: nil,
                                  primaryMuscle: nil,
                                  secondaryMuscles: [],
                                  isCustom: true)
    }

    // MARK: - Name normalization

    /// The single canonical normalization for exercise names. Trims and collapses
    /// internal whitespace so "bench   press" and " bench press " resolve to one lift
    /// instead of spawning near-duplicates — but **preserves the caller's casing**.
    /// That's the contract: case is preserved on first sighting (so a model-titlecased
    /// "Bench Press", an OCR-cased "BENCH PRESS", or a user-typed "bench press" each
    /// land as their own display string), and **subsequent matches are case-insensitive
    /// via `COLLATE NOCASE`** (see `exerciseID(canonicalNameMatching:)`) — so the same
    /// lift logged again in different casing folds onto the first sighting's row.
    /// `normalizeAlias` is the only other normalization, and it composes from this one.
    /// Fuzzy matching is Track 3.
    static func normalizeName(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Alias storage/lookup key: `normalizeName` then lowercased, so "DB Row" and
    /// "db   row" resolve to one alias. Composes from `normalizeName` so the
    /// trim/collapse rule is shared. Punctuation is deliberately *not* collapsed
    /// (that would merge distinct seeded aliases like "t bar row" and "tbar row");
    /// this keeps resolution parity with the prior JSON-column behavior.
    static func normalizeAlias(_ raw: String) -> String {
        normalizeName(raw).lowercased()
    }

    /// A stable slug from a display name: lowercase, drop apostrophes, and turn
    /// every run of non-alphanumerics into one underscore ("Close-Grip Bench
    /// Press" -> "close_grip_bench_press"). Mirrors how the seed authors slugs so
    /// a custom that later ships as a seed entry lines up on the same key.
    static func slugify(_ name: String) -> String {
        let cleaned = name.lowercased().replacingOccurrences(of: "'", with: "")
        return cleaned.split { !($0.isLetter || $0.isNumber) }.joined(separator: "_")
    }

    // MARK: - Reads

    func exerciseCount() throws -> Int { try count("SELECT COUNT(*) FROM exercises;") }

    /// Canonical display names for the FM layer's prompt (PR 8), most-used first so
    /// the `limit` keeps the lifts the user actually logs. A non-isolated read — it
    /// never writes, so the gated parser can fetch the user's known lifts without
    /// touching the write path. Exercises with no sets still appear (LEFT JOIN);
    /// validated against the v1 schema in sqlite3.
    func exerciseNames(limit: Int = 200) throws -> [String] {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT e.canonical_name, COUNT(s.id) AS uses
                FROM exercises e
                LEFT JOIN sets s ON s.exercise_id = e.id
                GROUP BY e.id
                ORDER BY uses DESC, e.canonical_name ASC
                LIMIT ?;
            """)
            defer { stmt.finalize() }
            stmt.bind(int: Int64(limit), at: 1)
            var names: [String] = []
            while try stmt.step() {
                if let name = stmt.text(0) { names.append(name) }
            }
            return names
        }
    }

    func exercise(id: Int64) throws -> Exercise? {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT slug, canonical_name, family_key, primary_muscle, secondary_muscles
                FROM exercises WHERE id = ?;
            """)
            defer { stmt.finalize() }
            stmt.bind(int: id, at: 1)
            guard try stmt.step() else { return nil }
            return Exercise(id: id,
                            slug: stmt.text(0) ?? "",
                            canonicalName: stmt.text(1) ?? "",
                            familyKey: stmt.text(2),
                            primaryMuscle: stmt.text(3),
                            secondaryMuscles: Self.decodeStringArray(stmt.text(4)))
        }
    }

    /// Owned aliases bucketed by exercise, for fuzzy suggestions and export —
    /// one query, sorted for a stable round-trip.
    func aliasesByExercise() throws -> [Int64: [String]] {
        try db.readTransaction {
            let stmt = try db.prepare("SELECT exercise_id, alias FROM exercise_aliases ORDER BY exercise_id, alias;")
            defer { stmt.finalize() }
            var map: [Int64: [String]] = [:]
            while try stmt.step() {
                map[stmt.int(0), default: []].append(stmt.text(1) ?? "")
            }
            return map
        }
    }

    // MARK: - Row-level writes (store-internal; the import path also inserts registry rows)

    @discardableResult
    func insertExercise(slug: String, canonicalName: String, familyKey: String?,
                        primaryMuscle: String?, secondaryMuscles: [String], isCustom: Bool) throws -> Int64 {
        let stmt = try db.prepare("""
            INSERT INTO exercises (slug, canonical_name, family_key, primary_muscle, secondary_muscles, is_custom, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        """)
        defer { stmt.finalize() }
        stmt.bind(text: slug, at: 1)
        stmt.bind(text: canonicalName, at: 2)
        stmt.bind(optionalText: familyKey, at: 3)
        stmt.bind(optionalText: primaryMuscle, at: 4)
        stmt.bind(text: Self.encode(secondaryMuscles), at: 5)
        stmt.bind(int: Int64(isCustom ? 1 : 0), at: 6)
        stmt.bind(text: Self.iso(Date()), at: 7)
        try stmt.step()
        return db.lastInsertRowID
    }

    /// Inserts a normalized alias, ignoring it if already owned. The PRIMARY KEY
    /// keeps an ambiguous term from pointing at two lifts, and "keep the existing
    /// owner on collision" is exactly the alias-merge rule (PR 9).
    func insertAlias(_ rawAlias: String, exerciseID: Int64) throws {
        let alias = Self.normalizeAlias(rawAlias)
        guard !alias.isEmpty else { return }
        let stmt = try db.prepare("INSERT OR IGNORE INTO exercise_aliases (alias, exercise_id) VALUES (?, ?);")
        defer { stmt.finalize() }
        stmt.bind(text: alias, at: 1)
        stmt.bind(int: exerciseID, at: 2)
        try stmt.step()
    }

    /// Refreshes seed-owned metadata on reseed without touching the (possibly
    /// user-renamed) display name or the is_custom flag.
    private func updateSeedMetadata(_ id: Int64, familyKey: String?, primaryMuscle: String?,
                                    secondaryMuscles: [String]) throws {
        let stmt = try db.prepare("""
            UPDATE exercises SET family_key = ?, primary_muscle = ?, secondary_muscles = ? WHERE id = ?;
        """)
        defer { stmt.finalize() }
        stmt.bind(optionalText: familyKey, at: 1)
        stmt.bind(optionalText: primaryMuscle, at: 2)
        stmt.bind(text: Self.encode(secondaryMuscles), at: 3)
        stmt.bind(int: id, at: 4)
        try stmt.step()
    }

    func exerciseID(slug: String) throws -> Int64? {
        let stmt = try db.prepare("SELECT id FROM exercises WHERE slug = ? LIMIT 1;")
        defer { stmt.finalize() }
        stmt.bind(text: slug, at: 1)
        return try stmt.step() ? stmt.int(0) : nil
    }

    /// A unique slug for a user-created lift: the slugified name, suffixed only if
    /// that slug is already taken, so a custom never collides with a seed slug.
    private func uniqueSlug(forName name: String) throws -> String {
        let base = Self.slugify(name)
        let stem = base.isEmpty ? "exercise" : base
        var candidate = stem
        var n = 2
        while try exerciseID(slug: candidate) != nil {
            candidate = "\(stem)_\(n)"
            n += 1
        }
        return candidate
    }

    private func updateCanonicalName(_ id: Int64, to name: String) throws {
        let stmt = try db.prepare("UPDATE exercises SET canonical_name = ? WHERE id = ?;")
        defer { stmt.finalize() }
        stmt.bind(text: name, at: 1)
        stmt.bind(int: id, at: 2)
        try stmt.step()
    }

    private func repointSets(from sourceID: Int64, to targetID: Int64) throws {
        let stmt = try db.prepare("UPDATE sets SET exercise_id = ? WHERE exercise_id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: targetID, at: 1)
        stmt.bind(int: sourceID, at: 2)
        try stmt.step()
    }

    private func repointAliases(from sourceID: Int64, to targetID: Int64) throws {
        // `alias` is the PK and is unchanged, so re-pointing the owner can't collide
        // (source and target can never share an alias string).
        let stmt = try db.prepare("UPDATE exercise_aliases SET exercise_id = ? WHERE exercise_id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: targetID, at: 1)
        stmt.bind(int: sourceID, at: 2)
        try stmt.step()
    }

    private func deleteExerciseRow(_ id: Int64) throws {
        let stmt = try db.prepare("DELETE FROM exercises WHERE id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        try stmt.step()
    }

    private func customAndUsage(_ id: Int64) throws -> (isCustom: Bool, used: Int)? {
        let stmt = try db.prepare("""
            SELECT is_custom, (SELECT COUNT(*) FROM sets WHERE exercise_id = exercises.id)
            FROM exercises WHERE id = ?;
        """)
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        guard try stmt.step() else { return nil }
        return (stmt.int(0) != 0, Int(stmt.int(1)))
    }

    // MARK: - Resolution helpers

    private func exerciseID(canonicalNameMatching name: String) throws -> Int64? {
        let stmt = try db.prepare("SELECT id FROM exercises WHERE canonical_name = ? COLLATE NOCASE LIMIT 1;")
        defer { stmt.finalize() }
        stmt.bind(text: name, at: 1)
        return try stmt.step() ? stmt.int(0) : nil
    }

    /// Owned aliases live in `exercise_aliases`, keyed by the normalized alias, so
    /// a lookup is a single indexed primary-key hit instead of a registry scan.
    private func exerciseID(aliasMatching name: String) throws -> Int64? {
        let stmt = try db.prepare("SELECT exercise_id FROM exercise_aliases WHERE alias = ? LIMIT 1;")
        defer { stmt.finalize() }
        stmt.bind(text: Self.normalizeAlias(name), at: 1)
        return try stmt.step() ? stmt.int(0) : nil
    }

    private static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
