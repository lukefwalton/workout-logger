import XCTest
@testable import WorkoutChatLog

@MainActor
final class ExerciseLibraryTests: XCTestCase {

    private var dbPath: String!
    private var store: WorkoutStore!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "wcl-lib-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: dbPath))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    private func makeSet(_ name: String, reps: Int = 8) -> SetDraft {
        SetDraft(exerciseName: name, weight: 135, unit: .lb, loadKind: .external,
                 reps: reps, rir: nil, setType: .working, notes: nil)
    }

    // MARK: - Merge

    func testMergeRepointsSetsAndDeletesSourceInOneTransaction() throws {
        let before = try store.exerciseCount()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
            sets: [makeSet("Bench Pres", reps: 5), makeSet("Bench Press", reps: 8)]))   // "Bench Pres" is a typo → custom
        let source = try XCTUnwrap(store.resolveExercise("Bench Pres"))
        let target = try XCTUnwrap(store.resolveExercise("Bench Press"))
        XCTAssertEqual(try store.exerciseCount(), before + 1, "the typo created one custom exercise")

        try store.mergeExercise(from: source, into: target)

        XCTAssertEqual(try store.exerciseCount(), before, "the source exercise is deleted")
        XCTAssertTrue(try store.sets(inSession: result.sessionID).allSatisfy { $0.exerciseID == target },
                      "all of the source's sets re-point to the target")
        XCTAssertEqual(try store.resolveExercise("Bench Pres"), target, "the source's old name folds in as an alias of target")
    }

    func testMergeFoldsSourceAliasesIntoTarget() throws {
        let source = try XCTUnwrap(store.resolveExercise("Romanian Deadlift"))   // owns alias "rdl"
        let target = try XCTUnwrap(store.resolveExercise("Deadlift"))
        try store.mergeExercise(from: source, into: target)
        XCTAssertEqual(try store.resolveExercise("rdl"), target, "the source's alias now resolves to target")
        XCTAssertNil(try store.exercise(id: source), "the source exercise is gone")
    }

    func testSelfMergeRejected() throws {
        let id = try XCTUnwrap(store.resolveExercise("Bench Press"))
        XCTAssertThrowsError(try store.mergeExercise(from: id, into: id)) {
            XCTAssertEqual($0 as? WorkoutStoreError, .selfMerge)
        }
    }

    // MARK: - Rename

    func testRenamePreservesIdentityAndSetAssociations() throws {
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [makeSet("Bench Press")]))
        let id = try XCTUnwrap(store.resolveExercise("Bench Press"))
        let slugBefore = try XCTUnwrap(store.exercise(id: id)?.slug)

        try store.renameExercise(id, to: "Barbell Bench Press")

        let renamed = try XCTUnwrap(store.exercise(id: id))
        XCTAssertEqual(renamed.canonicalName, "Barbell Bench Press")
        XCTAssertEqual(renamed.slug, slugBefore, "slug (the stable key) is unchanged")
        XCTAssertEqual(try store.resolveExercise("Barbell Bench Press"), id, "still the same identity")
        XCTAssertTrue(try store.sets(inSession: result.sessionID).allSatisfy { $0.exerciseID == id },
                      "logged sets still point at the same id")
    }

    func testRenameOntoAnotherExerciseRejected() throws {
        let incline = try XCTUnwrap(store.resolveExercise("Incline Bench Press"))
        XCTAssertThrowsError(try store.renameExercise(incline, to: "Bench Press")) {
            XCTAssertEqual($0 as? WorkoutStoreError, .renameCollision("Bench Press"))
        }
        XCTAssertEqual(try store.exercise(id: incline)?.canonicalName, "Incline Bench Press", "unchanged after rejection")
    }

    // MARK: - Delete

    func testDeleteUnusedCustomExercise() throws {
        let before = try store.exerciseCount()
        let id = try store.addExercise(named: "Jefferson Curl")
        try store.deleteExercise(id)
        XCTAssertNil(try store.resolveExercise("Jefferson Curl"))
        XCTAssertEqual(try store.exerciseCount(), before)
    }

    func testDeleteRejectsExerciseInUse() throws {
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [makeSet("Jefferson Curl")]))
        let id = try XCTUnwrap(store.resolveExercise("Jefferson Curl"))
        XCTAssertThrowsError(try store.deleteExercise(id)) {
            XCTAssertEqual($0 as? WorkoutStoreError, .exerciseInUse(1))
        }
    }

    func testDeleteRejectsSeededExercise() throws {
        let id = try XCTUnwrap(store.resolveExercise("Bench Press"))
        XCTAssertThrowsError(try store.deleteExercise(id)) {
            XCTAssertEqual($0 as? WorkoutStoreError, .cannotDeleteSeeded)
        }
    }

    // MARK: - Management read

    func testManagedExercisesCarryUsageAndCustomFlag() throws {
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
            sets: [makeSet("Bench Press"), makeSet("Bench Press")]))
        let managed = try store.managedExercises()
        let bench = try XCTUnwrap(managed.first { $0.canonicalName == "Bench Press" })
        XCTAssertEqual(bench.usageCount, 2)
        XCTAssertFalse(bench.isCustom)
        XCTAssertEqual(managed.count, 94)
    }
}
