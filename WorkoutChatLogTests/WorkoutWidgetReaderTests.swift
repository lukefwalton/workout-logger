import XCTest
@testable import WorkoutChatLog

/// The widget's read logic — open session wins, else most-recent finished, else empty.
/// Exercises the same SELECTs the widget runs (here on the store's own connection;
/// on device it's a separate cross-process connection, but the query is identical).
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
}
