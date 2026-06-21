import Foundation

/// Outcome of a successful write. `setIDs` are in submitted order. `achievements`
/// are any personal records detected **inside the same transaction** by comparing
/// the just-saved sets to each exercise's own prior history (§4); it defaults to
/// empty so existing call sites are undisturbed.
struct SaveResult: Equatable {
    let sessionID: Int64
    let setIDs: [Int64]
    let achievements: [Achievement]

    init(sessionID: Int64, setIDs: [Int64], achievements: [Achievement] = []) {
        self.sessionID = sessionID
        self.setIDs = setIDs
        self.achievements = achievements
    }
}

enum WorkoutStoreError: Error, Equatable, CustomStringConvertible {
    /// A second open session was requested while one is already in progress.
    /// The single-open invariant (§1) is maintained in code, not the schema.
    case openSessionExists
    /// A session edit set an end time earlier than its start time.
    case endBeforeStart
    /// Renaming would collide with another exercise's display name — likely a
    /// merge was intended.
    case renameCollision(String)
    /// Merge source and target are the same exercise.
    case selfMerge
    /// A custom exercise can't be deleted while sets still reference it.
    case exerciseInUse(Int)
    /// Seeded exercises aren't deletable (rename or merge instead).
    case cannotDeleteSeeded

    var description: String {
        switch self {
        case .openSessionExists:
            return "A workout is already in progress; finish it before starting another."
        case .endBeforeStart:
            return "A workout can't end before it starts."
        case .renameCollision(let name):
            return "Another exercise is already called \"\(name)\". Merge them instead of renaming."
        case .selfMerge:
            return "Can't merge an exercise into itself."
        case .exerciseInUse(let count):
            return "This exercise is used in \(count) set\(count == 1 ? "" : "s"). Merge it instead of deleting."
        case .cannotDeleteSeeded:
            return "Built-in exercises can't be deleted. Rename or merge instead."
        }
    }
}

/// An exercise as shown in the library-management UI: identity + how heavily it's
/// used + whether it's user-created (so only unused customs can be deleted).
struct ManagedExercise: Equatable, Identifiable {
    let id: Int64
    let canonicalName: String
    let familyKey: String?
    let primaryMuscle: String?
    let isCustom: Bool
    let usageCount: Int
}

/// A set as stored, returned by reads. Deliberately distinct from `SetDraft`
/// (the *input* shape): a draft is a proposal with no identity, a `StoredSet`
/// is a fact with database IDs.
struct StoredSet: Equatable {
    let id: Int64
    let exerciseID: Int64
    let setIndex: Int
    let setType: String
    let weight: Double
    let unit: String
    let loadKind: String
    let reps: Int
    let rir: Int?
    let notes: String?
    let sourceText: String?
}

/// One set from the most recent prior session, for the "last time" hint on the
/// confirm card (§4) — load + reps only, read-only and purely informational.
struct LastTimeSet: Equatable {
    let load: WorkoutLoad
    let reps: Int
}

/// A read-only snapshot of the last time an exercise was logged in a *finished*
/// session (§4). `startedAt` drives the "N days ago" relative label; `sets` are
/// in stored order. Nothing here is written — it only informs the next entry.
struct LastTime: Equatable {
    let startedAt: Date
    let sets: [LastTimeSet]
}

struct WorkoutLoad: Codable, Equatable {
    var kind: WorkoutLoadKind
    var amount: Double?
    var unit: WeightUnit?

    static func stored(kind: WorkoutLoadKind, weight: Double, unit: WeightUnit) -> WorkoutLoad {
        switch kind {
        case .external, .bodyweightPlus, .assisted:
            return WorkoutLoad(kind: kind, amount: weight, unit: unit)
        case .bodyweight:
            return WorkoutLoad(kind: kind, amount: nil, unit: nil)
        case .unspecified:
            return WorkoutLoad(kind: kind, amount: nil, unit: unit)
        }
    }

    /// The canonical (weight, unit) columns to persist for a load kind — the
    /// inverse of `stored(kind:weight:unit:)`. Loadless kinds store NULL so the
    /// nullable schema is meaningful and a bodyweight set never round-trips as
    /// "0 lb"; `loadKind` remains the source of truth either way.
    static func storedColumns(kind: WorkoutLoadKind, weight: Double, unit: WeightUnit) -> (weight: Double?, unit: String?) {
        switch kind {
        case .external, .bodyweightPlus, .assisted:
            return (weight, unit.rawValue)
        case .bodyweight:
            return (nil, nil)
        case .unspecified:
            return (nil, unit.rawValue)
        }
    }

    var displayText: String {
        switch kind {
        case .external:
            return formattedAmountWithUnit ?? "external load"
        case .bodyweight:
            return "BW"
        case .unspecified:
            return "unspecified"
        case .bodyweightPlus:
            guard let formattedAmountWithUnit else { return "BW + load" }
            return "BW + \(formattedAmountWithUnit)"
        case .assisted:
            guard let formattedAmountWithUnit else { return "assisted" }
            return "assisted \(formattedAmountWithUnit)"
        }
    }

    private var formattedAmountWithUnit: String? {
        guard let amount, let unit else { return nil }
        let value = amount.rounded() == amount ? String(Int(amount)) : String(amount)
        return "\(value) \(unit.rawValue)"
    }
}

struct WorkoutSetHistoryRow: Equatable {
    let sessionID: Int64
    let sessionName: String?
    let sessionNotes: String?
    let startedAt: String
    let sessionEndedAt: String?
    let sessionFeel: SessionFeel?
    let sessionIsDeload: Bool
    let setID: Int64
    let exerciseID: Int64
    let exerciseName: String
    let setIndex: Int
    let setType: SetType
    let load: WorkoutLoad
    let reps: Int
    let rir: Int?
    let notes: String?
    let sourceText: String?
    let primaryMuscle: String?      // e.primary_muscle — drives per-muscle analytics (PR 5)
}

struct WorkoutDataExport: Codable, Equatable {
    let schemaVersion: Int
    let exportedAt: String
    let app: String
    let analyticsPolicy: ExportedAnalyticsPolicy
    let exercises: [ExportedExercise]
    let sessions: [ExportedSession]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case app
        case analyticsPolicy = "analytics_policy"
        case exercises
        case sessions
    }
}

/// What an import did (or would do, for a dry-run preview).
struct ImportSummary: Equatable {
    var addedSessions = 0
    var addedSets = 0
    var addedExercises = 0
    var skippedSessions = 0

    var isEmpty: Bool { addedSessions == 0 && addedExercises == 0 && skippedSessions == 0 }
}

struct ExportedAnalyticsPolicy: Codable, Equatable {
    let hardSetRIRThreshold: Int
    let countNullRIRAsHard: Bool
    let workingEquivalentSetTypes: [String]

    enum CodingKeys: String, CodingKey {
        case hardSetRIRThreshold = "hard_set_rir_threshold"
        case countNullRIRAsHard = "count_null_rir_as_hard"
        case workingEquivalentSetTypes = "working_equivalent_set_types"
    }

    init(_ policy: AnalyticsPolicy) {
        hardSetRIRThreshold = policy.hardSetRIRThreshold
        countNullRIRAsHard = policy.countNullRIRAsHard
        workingEquivalentSetTypes = policy.workingEquivalentSetTypes.map(\.rawValue).sorted()
    }
}

struct ExportedExercise: Codable, Equatable {
    let id: Int64
    let slug: String
    let canonicalName: String
    let familyKey: String?
    let primaryMuscle: String?
    let secondaryMuscles: [String]
    let isCustom: Bool
    let aliases: [String]
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case slug
        case canonicalName = "canonical_name"
        case familyKey = "family_key"
        case primaryMuscle = "primary_muscle"
        case secondaryMuscles = "secondary_muscles"
        case isCustom = "is_custom"
        case aliases
        case createdAt = "created_at"
    }
}

struct ExportedSession: Codable, Equatable {
    let id: Int64
    let startedAt: String
    let endedAt: String?
    let name: String?
    let notes: String?
    let feel: String?
    let isDeload: Bool
    let createdAt: String
    var sets: [ExportedSet]

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case name
        case notes
        case feel
        case isDeload = "is_deload"
        case createdAt = "created_at"
        case sets
    }
}

struct ExportedSet: Codable, Equatable {
    let id: Int64
    let exerciseID: Int64
    let exerciseName: String
    let setIndex: Int
    let setType: String
    let load: WorkoutLoad
    let reps: Int
    let rir: Int?
    let notes: String?
    let sourceText: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case exerciseID = "exercise_id"
        case exerciseName = "exercise_name"
        case setIndex = "set_index"
        case setType = "set_type"
        case load
        case reps
        case rir
        case notes
        case sourceText = "source_text"
        case createdAt = "created_at"
    }
}

enum WorkoutShareSummary {
    static func aiPrompt(rows: [WorkoutSetHistoryRow],
                         days: Int,
                         includeNotes: Bool = false,
                         includeTrends: Bool = false) -> String {
        guard !rows.isEmpty else {
            return """
            Here is my recent training log. I do not have workout sets in this export window yet.

            Data window: last \(days) days
            """
        }

        let notesColumn = includeNotes ? " | Notes" : ""
        var lines = [
            "Here is my recent training log.",
            "",
            "Data window: last \(days) days",
            "Format: one row per logged set. This payload was prepared locally; I chose to share it.",
            "",
        ]

        if includeTrends {
            lines.append(contentsOf: trendSection(rows: rows))
            lines.append("")
        }

        lines.append(contentsOf: [
            "| Date | Exercise | Set | Load | Reps | RIR | Type\(notesColumn) |",
            "| --- | --- | ---: | --- | ---: | --- | ---\(includeNotes ? " | ---" : "") |"
        ])

        for row in rows {
            let rir = row.rir.map(String.init) ?? ""
            var cells = [
                row.startedAt,
                row.exerciseName,
                String(row.setIndex),
                row.load.displayText,
                String(row.reps),
                rir,
                row.setType.rawValue
            ]
            if includeNotes { cells.append(row.notes ?? "") }
            lines.append("| " + cells.map(escapeMarkdownTableCell).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private struct Trend {
        let exercise: String
        let sets: Int
        let sessions: Int
        let averageLoad: String
        let averageReps: String
        let averageRIR: String
        let loadTrend: String
    }

    private static func trendSection(rows: [WorkoutSetHistoryRow]) -> [String] {
        let trends = rows
            .grouped(by: { $0.exerciseName })
            .map { trend(for: $0.key, rows: $0.value) }
            .sorted { $0.exercise.localizedCaseInsensitiveCompare($1.exercise) == .orderedAscending }

        var lines = [
            "## Deterministic Trend Summary",
            "",
            "| Exercise | Sets | Sessions | Avg Load | Avg Reps | Avg RIR | Load Trend |",
            "| --- | ---: | ---: | --- | ---: | ---: | --- |"
        ]
        for trend in trends {
            lines.append("| " + [
                trend.exercise,
                String(trend.sets),
                String(trend.sessions),
                trend.averageLoad,
                trend.averageReps,
                trend.averageRIR,
                trend.loadTrend
            ].map(escapeMarkdownTableCell).joined(separator: " | ") + " |")
        }
        return lines
    }

    private static func trend(for exercise: String, rows: [WorkoutSetHistoryRow]) -> Trend {
        let sessions = Set(rows.map(\.sessionID)).count
        return Trend(exercise: exercise,
                     sets: rows.count,
                     sessions: sessions,
                     averageLoad: averageLoadText(rows),
                     averageReps: formattedAverage(rows.map { Double($0.reps) }),
                     averageRIR: formattedAverage(rows.compactMap { $0.rir.map(Double.init) }),
                     loadTrend: loadTrendText(rows))
    }

    private static func averageLoadText(_ rows: [WorkoutSetHistoryRow]) -> String {
        let amounts = comparableLoadAmounts(rows)
        guard !amounts.values.isEmpty else { return "n/a" }
        return "\(formattedAverage(amounts.values)) \(amounts.unit.rawValue)"
    }

    private static func loadTrendText(_ rows: [WorkoutSetHistoryRow]) -> String {
        let chronological = rows.sorted {
            if $0.startedAt == $1.startedAt { return $0.setID < $1.setID }
            return $0.startedAt < $1.startedAt
        }
        let amounts = comparableLoadAmounts(chronological)
        // The "never silently convert" doctrine: if loads span mixed units, surface why
        // the trend was omitted rather than reading as "n/a" alongside the genuinely-empty
        // case. (Conversion would invent a number — see the calorie estimate gate, §1.)
        if amounts.mixedUnits { return "(mixed units — trend omitted)" }
        guard amounts.values.count >= 2 else { return "n/a" }
        let split = max(1, amounts.values.count / 2)
        let early = average(amounts.values.prefix(split).map { $0 })
        let recent = average(amounts.values.suffix(amounts.values.count - split).map { $0 })
        let delta = recent - early
        guard abs(delta) >= 0.05 else { return "flat" }
        let sign = delta > 0 ? "+" : ""
        return "\(sign)\(formatted(delta)) \(amounts.unit.rawValue)"
    }

    private static func comparableLoadAmounts(_ rows: [WorkoutSetHistoryRow]) -> (values: [Double], unit: WeightUnit, mixedUnits: Bool) {
        let loads = rows.compactMap { row -> (Double, WeightUnit)? in
            guard [.external, .bodyweightPlus, .assisted].contains(row.load.kind),
                  let amount = row.load.amount,
                  let unit = row.load.unit else { return nil }
            return (amount, unit)
        }
        guard let unit = loads.first?.1 else { return ([], .lb, false) }
        guard loads.allSatisfy({ $0.1 == unit }) else { return ([], .lb, true) }
        return (loads.map(\.0), unit, false)
    }

    private static func formattedAverage(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        return formatted(average(values))
    }

    private static func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private static func formatted(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded() == rounded ? String(Int(rounded)) : String(rounded)
    }

    private static func escapeMarkdownTableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}

private extension Sequence {
    func grouped<Key: Hashable>(by key: (Element) -> Key) -> [Key: [Element]] {
        Dictionary(grouping: self, by: key)
    }
}

/// The one disciplined layer. Owns all SQL and the single write path. The app
/// (and, later, the on-device model) proposes a `WorkoutDraft`; this type
/// validates it, resolves each exercise against the canonical registry, and
/// writes it atomically. Nothing else writes to the database, and the model
/// never generates SQL.
/// `@unchecked Sendable` is sound because the only stored property is the
/// thread-safe `SQLiteDB` (FULLMUTEX) and write APIs are `@MainActor`-gated.
/// This unlocks off-main History/Progress reads — `setHistory` is a hot,
/// scrolling-frequency call after a year of data.
final class WorkoutStore: @unchecked Sendable {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    @MainActor
    func migrate() throws {
        try Schema.migrate(db)
    }

    /// The applied schema version. Exposed for diagnostics/tests; the raw
    /// connection stays private so feature code can't run ad hoc SQL and bypass
    /// validation — every workout write goes through `save`.
    func schemaVersion() throws -> Int {
        try db.userVersion()
    }

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
            guard try count("SELECT COUNT(*) FROM supplements;") == 0 else { return }
            for (index, preset) in Self.presetSupplements.enumerated() {
                try insertSupplementRow(name: preset.name, isPreset: true,
                                        tracksGrams: preset.tracksGrams, sortOrder: index)
            }
        }
    }

    /// The configured supplements, presets first. Non-isolated read.
    func supplements() throws -> [Supplement] {
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

    /// One day's intake keyed by supplement id (presence = taken). Non-isolated.
    func supplementIntake(onDay day: String) throws -> [Int64: SupplementIntake] {
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

    /// All intake on/after `sinceDay` ('YYYY-MM-DD'), oldest first — the raw history
    /// the trends analytics aggregates. Non-isolated read.
    func supplementHistory(sinceDay: String) throws -> [SupplementIntake] {
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

    // MARK: - Exercise library management (PR 9)

    /// Library entries with usage counts, for Settings → Exercises.
    func managedExercises() throws -> [ManagedExercise] {
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

    /// Non-mutating lookup: exact canonical (case-insensitive) -> alias -> nil.
    /// Safe to call from anywhere (a future confirm-card preview or quick-log)
    /// because it never writes. Track 3's embedding nearest-neighbor slots in
    /// between the alias step and `nil`. Rejects blank input so callers can't
    /// pretend whitespace is a real lift.
    func resolveExercise(_ rawName: String) throws -> Int64? {
        let name = Self.normalizeName(rawName)
        guard !name.isEmpty else { throw ParseError.emptyExerciseName }
        if let id = try exerciseID(canonicalNameMatching: name) { return id }
        return try exerciseID(aliasMatching: name)
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
        let aliasMap = try aliasesByExercise()
        let stmt = try db.prepare("SELECT id, canonical_name, family_key FROM exercises;")
        defer { stmt.finalize() }
        var hits: [ExerciseSuggestion] = []
        while try stmt.step() {
            let id = stmt.int(0)
            let name = stmt.text(1) ?? ""
            let candidates = [name] + (aliasMap[id] ?? [])
            let best = candidates.map { FuzzyMatch.similarity(query, $0) }.max() ?? 0
            if best >= Self.fuzzySuggestionThreshold {
                hits.append(ExerciseSuggestion(exerciseID: id, canonicalName: name,
                                               familyKey: stmt.text(2), score: best, via: .fuzzy))
            }
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
        let stmt = try db.prepare("SELECT id, canonical_name, family_key FROM exercises ORDER BY id;")
        defer { stmt.finalize() }
        var rows: [(id: Int64, name: String, familyKey: String?)] = []
        while try stmt.step() {
            rows.append((id: stmt.int(0), name: stmt.text(1) ?? "", familyKey: stmt.text(2)))
        }
        return rows
    }

    /// Resolve, creating a new muscle-less, user-correctable exercise when the
    /// name is unknown. Deliberately **private**: creating a permanent
    /// `exercises` row only ever happens inside the save transaction, so the
    /// single write path is enforced by the type rather than by convention. The
    /// future editable-registry surface will be the one other, intentional
    /// writer.
    @discardableResult
    private func resolveOrCreateExercise(_ rawName: String) throws -> Int64 {
        if let id = try resolveExercise(rawName) { return id }
        let name = Self.normalizeName(rawName)
        return try insertExercise(slug: try uniqueSlug(forName: name),
                                  canonicalName: name,
                                  familyKey: nil,
                                  primaryMuscle: nil,
                                  secondaryMuscles: [],
                                  isCustom: true)
    }

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

    // MARK: - Reads (UI counts, the future audit view, and tests)

    func exerciseCount() throws -> Int { try count("SELECT COUNT(*) FROM exercises;") }
    func sessionCount() throws -> Int { try count("SELECT COUNT(*) FROM workout_sessions;") }
    func setCount() throws -> Int { try count("SELECT COUNT(*) FROM sets;") }

    func setCount(inSession id: Int64) throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM sets WHERE session_id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        return try stmt.step() ? Int(stmt.int(0)) : 0
    }

    /// Per-session set-time span in seconds (MAX − MIN of `created_at`), for the
    /// calorie estimate's set-span duration fallback (PR 11). A single-set session
    /// yields 0 (the estimator applies its own small fallback). One query, keyed by
    /// session id. Non-isolated read. `created_at` is the store's fixed ISO8601, so
    /// MIN/MAX over the text equals the chronological min/max.
    func sessionSetSpans() throws -> [Int64: Double] {
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

    /// Canonical display names for the FM layer's prompt (PR 8), most-used first so
    /// the `limit` keeps the lifts the user actually logs. A non-isolated read — it
    /// never writes, so the gated parser can fetch the user's known lifts without
    /// touching the write path. Exercises with no sets still appear (LEFT JOIN);
    /// validated against the v1 schema in sqlite3.
    func exerciseNames(limit: Int = 200) throws -> [String] {
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

    /// Snapshot of the one in-progress session (ended_at IS NULL), or nil. A
    /// non-isolated read so the widget's separate process (PR 12) can call it.
    func currentOpenSession() throws -> OpenSession? {
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

    /// The "last time" hint (§4): the sets this exercise was logged with in its
    /// most recent **finished** session, or nil if it has none. A non-isolated read.
    /// The open (in-progress) session is excluded so "last time" always means a
    /// genuinely prior workout, never the one being added to right now. Canonical-
    /// only — keyed by `exercise_id`, so it never blends a different lift's history.
    /// Validated against the v1 schema in sqlite3 (open-excluded, most-recent-closed,
    /// skips sessions lacking the exercise; uses `idx_sets_exercise`).
    func lastTime(forExercise exerciseID: Int64) throws -> LastTime? {
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

    func exercise(id: Int64) throws -> Exercise? {
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

    /// A session's sets in stored order — the backbone of the future audit view
    /// and a convenient assertion target for tests.
    func sets(inSession sessionID: Int64) throws -> [StoredSet] {
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

    func setHistory(since startDate: Date? = nil, includeNotes: Bool = false) throws -> [WorkoutSetHistoryRow] {
        let start = startDate.map(Self.iso)
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

    func aiSharePrompt(lastDays days: Int = 30,
                       includeNotes: Bool = false,
                       includeTrends: Bool = false) throws -> String {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        return WorkoutShareSummary.aiPrompt(rows: try setHistory(since: start, includeNotes: includeNotes),
                                            days: days,
                                            includeNotes: includeNotes,
                                            includeTrends: includeTrends)
    }

    func dataExport(includeNotes: Bool = true, exportedAt: Date = Date()) throws -> WorkoutDataExport {
        let rows = try exportRows(includeNotes: includeNotes)
        var sessions = try exportSessions(includeNotes: includeNotes)
        for index in sessions.indices {
            sessions[index].sets = rows.filter { $0.sessionID == sessions[index].id }.map(\.set)
        }

        return WorkoutDataExport(schemaVersion: 2,   // 2: sessions carry ended_at / feel / is_deload
                                 exportedAt: Self.iso(exportedAt),
                                 app: "WorkoutChatLog",
                                 analyticsPolicy: ExportedAnalyticsPolicy(.default),
                                 exercises: try exportExercises(),
                                 sessions: sessions)
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
    /// absent/false for a v1 file (optional / defaulted fields).
    static func decodeExport(_ data: Data) throws -> WorkoutDataExport {
        try JSONDecoder().decode(WorkoutDataExport.self, from: data)
    }

    /// Restore an export by merging: match exercises by slug (create missing
    /// customs), then recreate each not-already-present session as a closed
    /// historical session with its sets (set_index renumbered 1…n through the same
    /// nullable-load contract as a fresh save). Idempotent — re-importing the same
    /// file skips sessions whose (started_at, set count, total reps) already exist.
    /// `dryRun` computes the same summary but writes nothing (one transaction,
    /// rolled back), for a pre-import preview.
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

    // MARK: - Inserts (private; every write funnels through here)

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

    @discardableResult
    private func insertExercise(slug: String, canonicalName: String, familyKey: String?,
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
    private func insertAlias(_ rawAlias: String, exerciseID: Int64) throws {
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

    private func exerciseID(slug: String) throws -> Int64? {
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

    private func count(_ sql: String) throws -> Int {
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        return try stmt.step() ? Int(stmt.int(0)) : 0
    }

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

    /// Owned aliases bucketed by exercise, for export — one query, sorted for a
    /// stable round-trip.
    private func aliasesByExercise() throws -> [Int64: [String]] {
        let stmt = try db.prepare("SELECT exercise_id, alias FROM exercise_aliases ORDER BY exercise_id, alias;")
        defer { stmt.finalize() }
        var map: [Int64: [String]] = [:]
        while try stmt.step() {
            map[stmt.int(0), default: []].append(stmt.text(1) ?? "")
        }
        return map
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

    // MARK: - Encoding helpers

    static func iso(_ date: Date) -> String { WorkoutDateFormat.string(date) }

    /// Parses an ISO8601 timestamp the store wrote with `iso(_:)`. nil for nil or
    /// unparseable input (e.g. a NULL ended_at on an open session).
    static func date(_ text: String?) -> Date? { WorkoutDateFormat.date(text) }

    private static func fileSafeTimestamp(_ date: Date = Date()) -> String {
        iso(date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "Z", with: "UTC")
    }

    private static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static func decodeStringArray(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array
    }
}
