import XCTest
@testable import WorkoutChatLog

/// Low-level storage guarantees that protect the data contract: atomic
/// transactions and FK-cascade deletes. Exercised against `SQLiteDB` + `Schema`
/// directly — the right altitude, since both are properties of the connection
/// and schema rather than the domain store (whose `db` is private).
final class SQLiteDBTests: XCTestCase {

    private var path: String!
    private var db: SQLiteDB!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "wcl-sqlite-\(UUID().uuidString).sqlite"
        db = try SQLiteDB(path: path)
        try Schema.migrate(db)
    }

    override func tearDownWithError() throws {
        db = nil   // close before deleting the file
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func count(_ table: String) throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { stmt.finalize() }
        return try stmt.step() ? Int(stmt.int(0)) : 0
    }

    func testMigrationStampsAndIsIdempotent() throws {
        XCTAssertEqual(try db.userVersion(), Schema.latestVersion)
        try Schema.migrate(db)   // second run is a no-op (and passes the v1.2-shape guard)
        XCTAssertEqual(try db.userVersion(), Schema.latestVersion)
    }

    func testMigrateRejectsIncompatibleLegacyDatabase() throws {
        let legacyPath = NSTemporaryDirectory() + "wcl-legacy-\(UUID().uuidString).sqlite"
        var legacy: SQLiteDB? = try SQLiteDB(path: legacyPath)
        defer {
            legacy = nil
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: legacyPath + suffix)
            }
        }
        // A pre-v1.2 exercises table (no slug column) stamped user_version = 1 —
        // migrate() must refuse it with a clear reset error, not no-op and let the
        // store hit missing-column SQL errors later.
        try legacy?.execute("""
            CREATE TABLE exercises (id INTEGER PRIMARY KEY, canonical_name TEXT NOT NULL, created_at TEXT NOT NULL);
            PRAGMA user_version = 1;
        """)
        let stale = try XCTUnwrap(legacy)
        XCTAssertThrowsError(try Schema.migrate(stale)) {
            XCTAssertEqual($0 as? Schema.MigrationError, .incompatibleLegacyDatabase)
        }
    }

    func testAtMostOneOpenSessionEnforcedByIndex() throws {
        try db.execute("INSERT INTO workout_sessions (started_at, created_at) VALUES ('t', 't');")   // open
        XCTAssertThrowsError(
            try db.execute("INSERT INTO workout_sessions (started_at, created_at) VALUES ('t2', 't2');"),
            "a second open (ended_at NULL) session is rejected by idx_one_open_session"
        )
        // a closed session alongside the open one is fine
        try db.execute("INSERT INTO workout_sessions (started_at, ended_at, created_at) VALUES ('t3', 't3', 't3');")
        XCTAssertEqual(try count("workout_sessions"), 2)
    }

    /// v1.2 is a clean v1 reset (zero installs) — there is no v2 ALTER path. The
    /// single schema literal bakes in the constraints that protect the data
    /// contract: a closed load-kind vocabulary, the rep cap, one set per
    /// (session, set_index), and a unique slug.
    func testV1SchemaEnforcesConstraints() throws {
        try db.execute("INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('bench_press', 'Bench Press', 't');")
        try db.execute("INSERT INTO workout_sessions (started_at, created_at) VALUES ('t', 't');")
        try db.execute("""
            INSERT INTO sets (session_id, exercise_id, set_index, load_kind, reps, set_type, created_at)
            VALUES (1, 1, 1, 'external', 8, 'working', 't');
        """)

        // Out-of-vocabulary load_kind is rejected by CHECK.
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO sets (session_id, exercise_id, set_index, load_kind, reps, set_type, created_at)
            VALUES (1, 1, 2, 'levitation', 8, 'working', 't');
        """))
        // Reps above the cap are rejected by CHECK.
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO sets (session_id, exercise_id, set_index, load_kind, reps, set_type, created_at)
            VALUES (1, 1, 3, 'external', 101, 'working', 't');
        """))
        // Out-of-vocabulary set_type is rejected by CHECK.
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO sets (session_id, exercise_id, set_index, load_kind, reps, set_type, created_at)
            VALUES (1, 1, 4, 'external', 8, 'levitating', 't');
        """))
        // Negative weight is rejected by CHECK (a NULL weight stays allowed).
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO sets (session_id, exercise_id, set_index, weight, load_kind, reps, set_type, created_at)
            VALUES (1, 1, 5, -5, 'external', 8, 'working', 't');
        """))
        // A duplicate (session_id, set_index) is rejected by UNIQUE.
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO sets (session_id, exercise_id, set_index, load_kind, reps, set_type, created_at)
            VALUES (1, 1, 1, 'external', 8, 'working', 't');
        """))
        // The slug is UNIQUE.
        XCTAssertThrowsError(try db.execute(
            "INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('bench_press', 'Dup', 't');"
        ))
    }

    func testTransactionCommitsOnSuccess() throws {
        try db.transaction {
            try db.execute("INSERT INTO workout_sessions (started_at, created_at) VALUES ('t', 't');")
        }
        XCTAssertEqual(try count("workout_sessions"), 1)
    }

    func testTransactionRollsBackOnError() throws {
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction {
            try db.execute("INSERT INTO workout_sessions (started_at, created_at) VALUES ('t', 't');")
            throw Boom()
        })
        XCTAssertEqual(try count("workout_sessions"), 0, "a failed transaction leaves nothing behind")
    }

    func testForeignKeyCascadeDeletesSets() throws {
        // Passes only when PRAGMA foreign_keys = ON and ON DELETE CASCADE fire.
        try db.execute("INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('test_lift', 'Test Lift', 't');")
        try db.execute("INSERT INTO workout_sessions (started_at, created_at) VALUES ('t', 't');")
        try db.execute("""
            INSERT INTO sets (session_id, exercise_id, set_index, load_kind, reps, set_type, created_at)
            VALUES (1, 1, 1, 'external', 5, 'working', 't');
        """)
        XCTAssertEqual(try count("sets"), 1)

        try db.execute("DELETE FROM workout_sessions WHERE id = 1;")
        XCTAssertEqual(try count("sets"), 0, "deleting a session cascades to its sets")
        XCTAssertEqual(try count("exercises"), 1, "exercises are not cascade-deleted")
    }

    /// `readTransaction` opens BEGIN DEFERRED, runs the body, commits, and
    /// returns the body's value. The minimum positive guarantee: two SELECTs
    /// inside the transaction don't crash, the closure's return is propagated,
    /// and a thrown error rolls back so the connection stays writable
    /// afterwards.
    func testReadTransactionRunsBodyAndCommits() throws {
        try db.execute("INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('bench', 'Bench', 't');")
        let observed = try db.readTransaction { try count("exercises") }
        XCTAssertEqual(observed, 1)
        // Connection still usable for writes after a clean read transaction.
        try db.execute("INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('squat', 'Squat', 't');")
        XCTAssertEqual(try count("exercises"), 2)
    }

    func testReadTransactionRollsBackOnThrow() throws {
        struct Boom: Error {}
        try db.execute("INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('bench', 'Bench', 't');")
        XCTAssertThrowsError(try db.readTransaction { () -> Void in throw Boom() })
        // After a ROLLBACK the connection is still in a clean state — a
        // subsequent BEGIN must succeed (no leftover open transaction).
        try db.execute("INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('squat', 'Squat', 't');")
        XCTAssertEqual(try count("exercises"), 2)
    }

    /// The widget's `readTransaction` is meant to give the two-query fallback
    /// (open session, last finished session) one consistent snapshot — a
    /// writer that commits between the two queries must not be visible to
    /// the second one.
    ///
    /// Verified here by opening a **separate** SQLite connection to the same
    /// file (WAL allows readers + one writer concurrently), starting a read
    /// transaction on the reader, then committing a write through the
    /// writer connection mid-read. The reader's second SELECT must still
    /// observe the pre-write state. After the reader commits, a fresh read
    /// sees the new row — proving the snapshot ended at COMMIT, not before.
    func testReadTransactionGivesConsistentSnapshotUnderConcurrentWrite() throws {
        try db.execute("INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('seeded', 'Seeded', 't');")

        // The widget opens its own connection — mirror that here.
        let widget = try SQLiteDB(path: path)

        func exerciseCount(on connection: SQLiteDB) throws -> Int {
            let stmt = try connection.prepare("SELECT COUNT(*) FROM exercises;")
            defer { stmt.finalize() }
            return try stmt.step() ? Int(stmt.int(0)) : 0
        }

        var observedInsideTxn: [Int] = []
        try widget.readTransaction {
            observedInsideTxn.append(try exerciseCount(on: widget))
            // Writer commits while the reader holds the deferred snapshot.
            try self.db.execute("INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('mid_read', 'Mid Read', 't');")
            observedInsideTxn.append(try exerciseCount(on: widget))
        }

        XCTAssertEqual(observedInsideTxn, [1, 1],
                       "Both queries inside the read transaction must see the pre-write snapshot")
        // After the read transaction completes, the writer's commit is visible.
        XCTAssertEqual(try exerciseCount(on: widget), 2)
    }

    func testAliasCascadeDeletesWithExercise() throws {
        try db.execute("INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('row', 'Barbell Row', 't');")
        try db.execute("INSERT INTO exercise_aliases (alias, exercise_id) VALUES ('bb row', 1);")
        XCTAssertEqual(try count("exercise_aliases"), 1)
        // An alias cannot be owned by two lifts (PRIMARY KEY).
        try db.execute("INSERT INTO exercises (slug, canonical_name, created_at) VALUES ('t_bar_row', 'T-Bar Row', 't');")
        XCTAssertThrowsError(try db.execute("INSERT INTO exercise_aliases (alias, exercise_id) VALUES ('bb row', 2);"))
        // Deleting the owning exercise cascades to its aliases.
        try db.execute("DELETE FROM exercises WHERE id = 1;")
        XCTAssertEqual(try count("exercise_aliases"), 0, "aliases cascade with their owning exercise")
    }
}
