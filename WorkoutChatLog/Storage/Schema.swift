import Foundation

/// The SQLite schema and its forward-only migrations, tracked by
/// `PRAGMA user_version`. Each migration bumps the version inside its own
/// transaction so a half-applied schema can never be left behind.
///
/// v1.2 is a clean reset (the app has never shipped — zero installs), so there
/// is exactly one schema literal with every constraint baked in: the flat
/// exercise-identity model (slug / family_key / owned aliases, §1.1) and the
/// full session schema (ended_at / feel / is_deload) the session lifecycle
/// (PR 3) needs. The migration framework and `user_version` stay intact so
/// genuine *post-launch* updates remain non-destructive — that's the future
/// this protects, not the past.
enum Schema {
    static let latestVersion = 2

    enum MigrationError: Error, Equatable, CustomStringConvertible {
        /// A database from before the v1.2 reset (stamped user_version 1 or 2 with
        /// the old shape). The app has never shipped, so there is nothing to
        /// migrate — the only fix is a clean install.
        case incompatibleLegacyDatabase

        var description: String {
            switch self {
            case .incompatibleLegacyDatabase:
                return "This local database predates the v1.2 schema reset. Private Workout Logger has never shipped, "
                     + "so there is nothing to migrate — delete the app (or wipe its App Group container) and "
                     + "relaunch for a clean install."
            }
        }
    }

    static func migrate(_ db: SQLiteDB) throws {
        let version = try db.userVersion()
        if version == 0 {
            // Fresh install: lay down the full current schema (every version) in one
            // transaction.
            try db.transaction {
                try db.execute(v1)
                try db.execute(v2)
                try db.setUserVersion(latestVersion)
            }
            return
        }
        // A non-empty database that predates the v1.2 reset was stamped
        // user_version 1 or 2 with an incompatible shape (no slug / no
        // exercise_aliases). Zero installs means there is nothing to preserve, so
        // rather than no-op and let the store hit missing-column SQL errors later,
        // fail loudly with a clear reset instruction.
        guard try columnExists(db, table: "exercises", column: "slug") else {
            throw MigrationError.incompatibleLegacyDatabase
        }
        // Forward, non-destructive migrations for an already-v1.2 database. Each step
        // bumps user_version inside its own transaction so a half-applied schema can't
        // be left behind.
        if version < 2 {
            try db.transaction {
                try db.execute(v2)
                try db.setUserVersion(2)
            }
        }
    }

    private static func columnExists(_ db: SQLiteDB, table: String, column: String) throws -> Bool {
        let stmt = try db.prepare("PRAGMA table_info(\(table));")
        defer { stmt.finalize() }
        while try stmt.step() {
            if stmt.text(1) == column { return true }
        }
        return false
    }

    private static let v1 = """
    CREATE TABLE workout_sessions (
        id INTEGER PRIMARY KEY,
        started_at TEXT NOT NULL,
        ended_at  TEXT,                          -- NULL = open/in-progress (at most one — see idx_one_open_session)
        name TEXT,
        notes TEXT,
        feel TEXT,                               -- SessionFeel rawValue or NULL
        is_deload INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
    );

    -- At most one in-progress session. A UNIQUE index over the constant
    -- (ended_at IS NULL), restricted to open rows, makes the single-open
    -- invariant (§1) a database guarantee — not just caller discipline — so even
    -- a future second writer (the widget process, PR 12) can't open two at once.
    CREATE UNIQUE INDEX idx_one_open_session ON workout_sessions((ended_at IS NULL)) WHERE ended_at IS NULL;

    -- Flat, canonical exercise identity (§1.1). `id` is the immutable rowid that
    -- sets.exercise_id references; `slug` is the stable seed/import key;
    -- `canonical_name` is the mutable display name (not UNIQUE — rename/merge in
    -- PR 9 can briefly produce duplicates, and nothing logged points at the name).
    CREATE TABLE exercises (
        id INTEGER PRIMARY KEY,
        slug TEXT NOT NULL UNIQUE,
        canonical_name TEXT NOT NULL,
        family_key TEXT,                         -- e.g. "push_up"; NULL = singleton; non-analytical by default
        primary_muscle TEXT,
        secondary_muscles TEXT NOT NULL DEFAULT '[]',  -- JSON array (stored, not counted at launch)
        is_custom INTEGER NOT NULL DEFAULT 0,    -- user-created vs seeded
        created_at TEXT NOT NULL
    );
    CREATE INDEX idx_exercises_family ON exercises(family_key);
    CREATE INDEX idx_exercises_muscle ON exercises(primary_muscle);

    -- One alias -> exactly one canonical. The PRIMARY KEY is the global-uniqueness
    -- guarantee: an ambiguous term cannot be inserted as an alias of two lifts, so
    -- it falls through to suggest/clarify (PR 7/8) instead of resolving wrong.
    CREATE TABLE exercise_aliases (
        alias TEXT PRIMARY KEY,                  -- normalized: lowercased, whitespace-collapsed
        exercise_id INTEGER NOT NULL REFERENCES exercises(id) ON DELETE CASCADE
    );

    -- A set as stored. weight/unit are nullable for genuinely loadless work, but
    -- every other column keeps a DB-level CHECK so the schema — not just the save
    -- path — rejects bad data from any future writer (import, migration). The
    -- closed vocabularies (load_kind, set_type, unit) and the rep cap live here so
    -- the database itself stays the last line of integrity defense.
    CREATE TABLE sets (
        id INTEGER PRIMARY KEY,
        session_id INTEGER NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
        exercise_id INTEGER NOT NULL REFERENCES exercises(id),
        set_index INTEGER NOT NULL CHECK (set_index >= 1),
        weight REAL CHECK (weight IS NULL OR weight >= 0),
        unit TEXT CHECK (unit IS NULL OR unit IN ('lb','kg')),
        load_kind TEXT NOT NULL CHECK (load_kind IN ('external','bodyweight','unspecified','bodyweightPlus','assisted')),
        reps INTEGER NOT NULL CHECK (reps BETWEEN 1 AND 100),
        rir INTEGER CHECK (rir IS NULL OR rir BETWEEN 0 AND 10),
        set_type TEXT NOT NULL CHECK (set_type IN ('working','warmup','dropset','myorep','amrap','backoff')),
        notes TEXT,
        source_text TEXT,
        created_at TEXT NOT NULL,
        UNIQUE(session_id, set_index)
    );

    CREATE INDEX idx_sets_exercise ON sets(exercise_id);
    CREATE INDEX idx_sets_session ON sets(session_id);
    """

    // v2: daily supplement tracking. Separate from workout data but in the same
    // single-source-of-truth store, so intake history (and protein grams) can trend
    // over time like everything else. `supplements` is the configured list (Creatine
    // + Protein presets, plus user customs); `supplement_intake` is one row per
    // supplement per local day (presence = taken), with optional grams.
    private static let v2 = """
    CREATE TABLE supplements (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        is_preset INTEGER NOT NULL DEFAULT 0,    -- presets can't be removed
        tracks_grams INTEGER NOT NULL DEFAULT 0, -- Protein tracks grams; others are a checkbox
        sort_order INTEGER NOT NULL,             -- display order (presets first)
        created_at TEXT NOT NULL
    );

    -- One row per supplement per local calendar day ('YYYY-MM-DD'); the row's
    -- existence means "taken that day". grams is optional and only meaningful when
    -- the supplement tracks_grams. UNIQUE keeps it idempotent (toggle = insert/delete,
    -- grams edit = upsert).
    CREATE TABLE supplement_intake (
        id INTEGER PRIMARY KEY,
        supplement_id INTEGER NOT NULL REFERENCES supplements(id) ON DELETE CASCADE,
        day TEXT NOT NULL,
        grams REAL CHECK (grams IS NULL OR grams >= 0),
        created_at TEXT NOT NULL,
        UNIQUE(supplement_id, day)
    );
    CREATE INDEX idx_supplement_intake_day ON supplement_intake(day);
    """
}
