import XCTest
@testable import WorkoutChatLog

/// The widget's read logic — open session wins, else the newer of the last
/// finished workout and the last cardio bout, else empty. Exercises the same
/// SELECTs the widget runs (here on the store's own connection; on device it's a
/// separate cross-process connection, but the query is identical).
@MainActor
final class WorkoutWidgetReaderTests: XCTestCase {

    private var path: String!
    private var db: SQLiteDB!
    private var store: WorkoutStore!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "wcl-widget-\(UUID().uuidString).sqlite"
        db = try SQLiteDB(path: path)
        store = WorkoutStore(db: db)
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
    }

    override func tearDownWithError() throws {
        store = nil
        db = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func bench(_ count: Int) -> WorkoutDraft {
        WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                     sets: (0..<count).map { _ in
                         SetDraft(exerciseName: "Bench Press", weight: 135, unit: .lb,
                                  loadKind: .external, reps: 8)
                     })
    }

    func testEmptyWhenNothingLogged() {
        XCTAssertEqual(WorkoutWidgetReader.snapshot(db: db), .empty)
    }

    func testCurrentWhileASessionIsOpen() throws {
        _ = try store.save(bench(2))
        XCTAssertEqual(WorkoutWidgetReader.snapshot(db: db), .current(sets: 2))
    }

    func testLastWorkoutAfterFinishing() throws {
        let result = try store.save(bench(3))
        try store.finishSession(result.sessionID, name: "Push day", notes: nil, feel: nil, isDeload: false)

        guard case .last(let name, _, let sets) = WorkoutWidgetReader.snapshot(db: db) else {
            return XCTFail("expected a finished-workout snapshot")
        }
        XCTAssertEqual(name, "Push day")
        XCTAssertEqual(sets, 3)
    }

    func testOpenSessionWinsOverAPriorFinishedOne() throws {
        // Finish one workout, then start another (open) — the widget shows the open one.
        let first = try store.save(bench(2))
        try store.finishSession(first.sessionID, name: nil, notes: nil, feel: nil, isDeload: false)
        _ = try store.save(bench(1))
        XCTAssertEqual(WorkoutWidgetReader.snapshot(db: db), .current(sets: 1))
    }

    func testMalformedEndedAtDegradesToEmpty() throws {
        // A finished session whose ended_at can't be parsed → the reader logs and
        // returns nil for "last" rather than a fabricated date, so it degrades to
        // .empty. Pins the parse-failure path so it can't silently regress.
        try db.execute("""
            INSERT INTO workout_sessions (started_at, ended_at, created_at)
            VALUES ('2026-05-29T10:00:00Z', 'not-a-timestamp', '2026-05-29T10:00:00Z');
        """)
        XCTAssertEqual(WorkoutWidgetReader.snapshot(db: db), .empty)
    }

    // MARK: - Cardio (schema v3)

    private func cardio(_ activity: String, seconds: Int? = nil, distance: Double? = nil,
                        unit: CardioDistanceUnit? = nil, at: Date) -> CardioDraft {
        var draft = CardioDraft(activity: activity, durationSeconds: seconds,
                                distance: distance, distanceUnit: unit,
                                notes: nil, sourceText: nil)
        draft.loggedAt = at
        return draft
    }

    func testCardioOnlyStoreShowsLastCardio() throws {
        let when = Date(timeIntervalSince1970: 1_000_000)
        try store.saveCardio(cardio("Run", seconds: 1800, distance: 5, unit: .km, at: when))

        guard case .lastCardio(let activity, let seconds, let distance, let unit, let loggedAt)
                = WorkoutWidgetReader.snapshot(db: db) else {
            return XCTFail("expected a cardio snapshot for a cardio-only store")
        }
        XCTAssertEqual(activity, "Run")
        XCTAssertEqual(seconds, 1800)
        XCTAssertEqual(distance, 5)
        XCTAssertEqual(unit, .km)
        XCTAssertEqual(loggedAt, when)
    }

    func testCardioWinsWhenNewerThanLastFinishedWorkout() throws {
        let result = try store.save(bench(2))
        try store.finishSession(result.sessionID, name: nil, notes: nil, feel: nil, isDeload: false)
        try store.saveCardio(cardio("Run", seconds: 600, at: Date().addingTimeInterval(3600)))

        guard case .lastCardio(let activity, _, _, _, _) = WorkoutWidgetReader.snapshot(db: db) else {
            return XCTFail("expected the newer cardio bout to win")
        }
        XCTAssertEqual(activity, "Run")
    }

    func testFinishedWorkoutWinsWhenNewerThanCardio() throws {
        try store.saveCardio(cardio("Run", seconds: 600, at: Date(timeIntervalSince1970: 0)))
        let result = try store.save(bench(2))
        try store.finishSession(result.sessionID, name: "Push", notes: nil, feel: nil, isDeload: false)

        guard case .last(let name, _, _) = WorkoutWidgetReader.snapshot(db: db) else {
            return XCTFail("expected the newer finished workout to win")
        }
        XCTAssertEqual(name, "Push")
    }

    func testOpenSessionWinsOverNewerCardio() throws {
        try store.saveCardio(cardio("Run", seconds: 600, at: Date().addingTimeInterval(3600)))
        _ = try store.save(bench(1))
        XCTAssertEqual(WorkoutWidgetReader.snapshot(db: db), .current(sets: 1),
                       "an in-progress workout always beats a logged bout")
    }

    func testMalformedCardioLoggedAtFallsBackToStrength() throws {
        // An unparseable logged_at → the cardio candidate logs and drops out, so
        // the reader falls back to the last finished workout (and to .empty when
        // there is none) instead of fabricating "cardio = now".
        try db.execute("""
            INSERT INTO cardio_entries (activity, logged_at, created_at)
            VALUES ('Run', 'not-a-timestamp', '2026-05-29T10:00:00Z');
        """)
        let result = try store.save(bench(2))
        try store.finishSession(result.sessionID, name: "Push", notes: nil, feel: nil, isDeload: false)

        guard case .last(let name, _, _) = WorkoutWidgetReader.snapshot(db: db) else {
            return XCTFail("expected the strength fallback")
        }
        XCTAssertEqual(name, "Push")
    }

    func testMalformedCardioOnlyDegradesToEmpty() throws {
        try db.execute("""
            INSERT INTO cardio_entries (activity, logged_at, created_at)
            VALUES ('Run', 'not-a-timestamp', '2026-05-29T10:00:00Z');
        """)
        XCTAssertEqual(WorkoutWidgetReader.snapshot(db: db), .empty)
    }

    func testMalformedEndedAtFallsBackToCardio() throws {
        // Deliberate change from the pre-cardio behavior (which degraded straight
        // to .empty): when the last finished session's ended_at is corrupt, a
        // valid cardio bout is a better answer than nothing. Pinned so the
        // precedence change is a documented decision, not an accident.
        try db.execute("""
            INSERT INTO workout_sessions (started_at, ended_at, created_at)
            VALUES ('2026-05-29T10:00:00Z', 'not-a-timestamp', '2026-05-29T10:00:00Z');
        """)
        try store.saveCardio(cardio("Walk", seconds: 900, at: Date(timeIntervalSince1970: 1_000)))

        guard case .lastCardio(let activity, _, _, _, _) = WorkoutWidgetReader.snapshot(db: db) else {
            return XCTFail("expected the valid cardio bout to win over a corrupt strength timestamp")
        }
        XCTAssertEqual(activity, "Walk")
    }
}
