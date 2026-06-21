import XCTest
@testable import WorkoutChatLog

@MainActor
final class ImportTests: XCTestCase {

    private var paths: [String] = []

    override func tearDownWithError() throws {
        for path in paths {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        paths = []
    }

    private func makeStore(_ tag: String) throws -> WorkoutStore {
        let path = NSTemporaryDirectory() + "wcl-import-\(tag)-\(UUID().uuidString).sqlite"
        paths.append(path)
        let store = WorkoutStore(db: try SQLiteDB(path: path))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
        return store
    }

    private func makeSet(_ name: String, _ weight: Double, _ reps: Int, kind: WorkoutLoadKind = .external) -> SetDraft {
        SetDraft(exerciseName: name, weight: weight, unit: .lb, loadKind: kind, reps: reps, rir: nil, setType: .working, notes: nil)
    }

    private func signature(_ rows: [WorkoutSetHistoryRow]) -> [String] {
        rows.map {
            "\($0.exerciseName)|\($0.load.displayText)|\($0.reps)|\($0.setType.rawValue)|"
            + "\($0.sessionName ?? "")|\($0.sessionFeel?.rawValue ?? "")|\($0.sessionIsDeload)"
        }
    }

    func testJSONRoundTripReproducesSessionsSetsExercises() throws {
        let source = try makeStore("src")
        let push = try source.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0), name: "Push", notes: "good",
            sets: [makeSet("Bench Press", 135, 8), makeSet("Pull-Up", 0, 10, kind: .bodyweight)]))
        try source.finishSession(push.sessionID, name: nil, notes: nil, feel: .solid, isDeload: false)
        _ = try source.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 86_400), name: nil, notes: nil,
            sets: [makeSet("Jefferson Curl", 95, 8)]))   // a custom lift

        let export = try source.dataExport(includeNotes: true)

        let fresh = try makeStore("dst")
        let summary = try fresh.importData(export)
        XCTAssertEqual(summary.addedSessions, 2)
        XCTAssertEqual(summary.addedSets, 3)
        XCTAssertEqual(summary.addedExercises, 1, "only the custom lift is created; seeded lifts match by slug")

        XCTAssertEqual(try fresh.sessionCount(), 2)
        XCTAssertEqual(try fresh.setCount(), 3)
        XCTAssertEqual(signature(try source.setHistory(includeNotes: true)),
                       signature(try fresh.setHistory(includeNotes: true)),
                       "round-trip reproduces every set by content")
    }

    func testReimportIsIdempotent() throws {
        let source = try makeStore("src2")
        _ = try source.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0), name: nil, notes: nil,
            sets: [makeSet("Bench Press", 135, 8)]))
        let export = try source.dataExport()

        let fresh = try makeStore("dst2")
        XCTAssertEqual(try fresh.importData(export).addedSessions, 1)
        let second = try fresh.importData(export)
        XCTAssertEqual(second.addedSessions, 0, "re-importing the same file adds nothing")
        XCTAssertEqual(second.skippedSessions, 1)
        XCTAssertEqual(try fresh.sessionCount(), 1, "no duplicate session")
    }

    func testDryRunPreviewsWithoutWriting() throws {
        let source = try makeStore("src3")
        _ = try source.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
            sets: [makeSet("Bench Press", 135, 8), makeSet("Jefferson Curl", 95, 8)]))
        let export = try source.dataExport()

        let fresh = try makeStore("dst3")
        let preview = try fresh.importData(export, dryRun: true)
        XCTAssertEqual(preview.addedSessions, 1)
        XCTAssertEqual(preview.addedExercises, 1)
        XCTAssertEqual(try fresh.sessionCount(), 0, "a dry-run writes nothing")
        XCTAssertEqual(try fresh.exerciseCount(), 89, "…not even the custom exercise")
    }

    func testMalformedFileFailsCleanly() throws {
        XCTAssertThrowsError(try WorkoutStore.decodeExport(Data("definitely not json".utf8)))
    }
}
