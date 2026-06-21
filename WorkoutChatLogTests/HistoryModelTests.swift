import XCTest
@testable import WorkoutChatLog

@MainActor
final class HistoryModelTests: XCTestCase {

    private var dbPath: String!
    private var store: WorkoutStore!
    private var model: HistoryModel!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "wcl-hist-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: dbPath))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
        model = HistoryModel(store: store)
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    private func makeSet(_ name: String, weight: Double = 135, reps: Int = 8) -> SetDraft {
        SetDraft(exerciseName: name, weight: weight, unit: .lb, loadKind: .external,
                 reps: reps, rir: nil, setType: .working, notes: nil)
    }

    func testEmptyStateWhenNothingLogged() async {
        await model.load()
        XCTAssertEqual(model.state, .empty)
    }

    func testGroupsBySessionNewestFirstWithRowsInOrder() async throws {
        let first = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0), name: "Day 1", notes: nil,
                                                sets: [makeSet("Bench Press"), makeSet("Bench Press")]))
        try store.finishSession(first.sessionID, name: nil, notes: nil, feel: nil, isDeload: false)
        _ = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 86_400), name: "Day 2", notes: nil,
                                        sets: [makeSet("Overhead Press")]))

        await model.load()
        guard case .loaded(let sections) = model.state else { return XCTFail("expected loaded state") }
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.first?.title, "Day 2", "newest session is first")
        XCTAssertEqual(sections.first?.setCount, 1)
        XCTAssertEqual(sections.last?.title, "Day 1")
        XCTAssertEqual(sections.last?.setCount, 2)
        XCTAssertEqual(sections.last?.rows.map(\.setIndex), [1, 2], "rows within a session are in set order")
    }

    func testDeleteSetReloadsModelState() async throws {
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press"), makeSet("Bench Press")]))
        await model.load()
        model.deleteSet(result.setIDs[0])
        // The reload-after-delete is dispatched via `pendingReload` so the
        // caller doesn't block; tests `await` that handle for a deterministic
        // "post-mutation state is current" point.
        await model.pendingReload?.value
        guard case .loaded(let sections) = model.state else { return XCTFail("expected loaded state") }
        XCTAssertEqual(sections.first?.setCount, 1, "the model reflects the delete after its reload")
    }

    func testInvalidSetEditReturnsMessageAndLeavesDataUnchanged() async throws {
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press", reps: 8)]))
        await model.load()
        let message = model.updateSet(result.setIDs[0], exerciseName: "Bench Press", weight: 135, unit: .lb,
                                      loadKind: .external, reps: 0, rir: nil, setType: .working, notes: nil)
        XCTAssertNotNil(message, "an invalid edit returns an error message for the editor")
        XCTAssertEqual(try store.sets(inSession: result.sessionID).first?.reps, 8, "data is unchanged")
    }

    func testSessionsSharingATimestampStayDistinct() async throws {
        let sameTime = Date(timeIntervalSince1970: 1000)
        let first = try store.save(WorkoutDraft(startedAt: sameTime, name: "A", notes: nil, sets: [makeSet("Bench Press")]))
        try store.finishSession(first.sessionID, name: nil, notes: nil, feel: nil, isDeload: false)
        let second = try store.save(WorkoutDraft(startedAt: sameTime, name: "B", notes: nil, sets: [makeSet("Overhead Press")]))
        XCTAssertNotEqual(first.sessionID, second.sessionID)

        await model.load()
        guard case .loaded(let sections) = model.state else { return XCTFail("expected loaded state") }
        XCTAssertEqual(sections.count, 2, "same-timestamp sessions stay two distinct sections, not split or merged")
        XCTAssertEqual(Set(sections.map(\.id)), [first.sessionID, second.sessionID])
        XCTAssertTrue(sections.allSatisfy { $0.setCount == 1 })
    }

    /// Two `load()`s started together must converge to the same final state and
    /// not crash. The race-guard token guarantees the newer result wins; this
    /// test exercises the reentrant path (same input ⇒ same output is the
    /// boring-but-correct outcome).
    func testOverlappingLoadsConvergeWithoutCrashing() async throws {
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                        sets: [makeSet("Bench Press")]))
        async let first: () = model.load()
        async let second: () = model.load()
        _ = await (first, second)
        guard case .loaded(let sections) = model.state else { return XCTFail("expected loaded state") }
        XCTAssertEqual(sections.first?.setCount, 1)
    }
}
