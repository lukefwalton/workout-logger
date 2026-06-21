import XCTest
@testable import WorkoutChatLog

@MainActor
final class ProgressAnalyticsTests: XCTestCase {

    private var dbPath: String!
    private var store: WorkoutStore!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "wcl-prog-\(UUID().uuidString).sqlite"
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

    private func set(_ name: String, _ weight: Double, _ reps: Int, rir: Int? = nil,
                     kind: WorkoutLoadKind = .external, type: SetType = .working) -> SetDraft {
        SetDraft(exerciseName: name, weight: weight, unit: .lb, loadKind: kind,
                 reps: reps, rir: rir, setType: type, notes: nil)
    }

    private func rows() throws -> [WorkoutSetHistoryRow] { try store.setHistory(since: nil, includeNotes: false) }
    private func id(_ name: String) throws -> Int64 { try XCTUnwrap(store.resolveExercise(name)) }

    func testE1RMTakesTopSetPerSession() throws {
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
            sets: [set("Bench Press", 100, 5), set("Bench Press", 120, 3)]))
        let series = ProgressAnalytics.e1RMSeries(try rows(), exerciseID: try id("Bench Press"), policy: .default)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.value ?? 0, 132, accuracy: 0.01)   // 120 * (1 + 3/30), the top set
    }

    func testVolumeSumsTheSession() throws {
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
            sets: [set("Bench Press", 100, 5), set("Bench Press", 120, 3)]))
        let series = ProgressAnalytics.volumeSeries(try rows(), exerciseID: try id("Bench Press"), policy: .default)
        XCTAssertEqual(series.first?.value ?? 0, 860, accuracy: 0.01)   // 100*5 + 120*3
    }

    func testE1RMDropsHighRepSets() throws {
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [set("Bench Press", 95, 20)]))
        XCTAssertTrue(ProgressAnalytics.e1RMSeries(try rows(), exerciseID: try id("Bench Press"), policy: .default).isEmpty,
                      "reps above the cap are unreliable for e1RM and produce no point")
    }

    func testOffDaySessionExcludedFromTrendUnlessPolicyDisabled() throws {
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [set("Bench Press", 135, 5)]))
        try store.finishSession(result.sessionID, name: nil, notes: nil, feel: .off, isDeload: false)
        let benchID = try id("Bench Press")
        var excluding = AnalyticsPolicy.default; excluding.excludeOffDays = true
        var including = AnalyticsPolicy.default; including.excludeOffDays = false
        XCTAssertTrue(ProgressAnalytics.e1RMSeries(try rows(), exerciseID: benchID, policy: excluding).isEmpty,
                      "off day dropped from trends")
        XCTAssertEqual(ProgressAnalytics.e1RMSeries(try rows(), exerciseID: benchID, policy: including).count, 1,
                       "…but included when the toggle is off")
    }

    func testHardSetCountMatchesPolicy() throws {
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
            sets: [set("Bench Press", 135, 5, rir: 2), set("Bench Press", 135, 5, rir: 8)]))
        let chest = ProgressAnalytics.muscleWeeklyHardSets(try rows(), policy: .default).filter { $0.muscle == "chest" }
        XCTAssertEqual(chest.reduce(0) { $0 + $1.hardSets }, 1, "rir 2 is hard (≤4); rir 8 is not")
    }

    func testTwoCanonicalsInSameFamilyStaySeparateSeries() throws {
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
            sets: [set("Bench Press", 100, 5), set("Incline Bench Press", 60, 5)]))
        let bench = ProgressAnalytics.volumeSeries(try rows(), exerciseID: try id("Bench Press"), policy: .default)
        let incline = ProgressAnalytics.volumeSeries(try rows(), exerciseID: try id("Incline Bench Press"), policy: .default)
        XCTAssertEqual(bench.first?.value ?? 0, 500, accuracy: 0.01, "bench series excludes incline — no family collapse")
        XCTAssertEqual(incline.first?.value ?? 0, 300, accuracy: 0.01)
    }

    func testBodyweightLiftGetsRepsSeriesNotE1RM() throws {
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
            sets: [set("Pull-Up", 0, 10, kind: .bodyweight), set("Pull-Up", 0, 8, kind: .bodyweight)]))
        let pullupID = try id("Pull-Up")
        let option = try XCTUnwrap(ProgressAnalytics.exercises(try rows()).first { $0.id == pullupID })
        XCTAssertTrue(option.isBodyweight)
        XCTAssertEqual(ProgressAnalytics.repsSeries(try rows(), exerciseID: pullupID, policy: .default).first?.value, 10)
        XCTAssertTrue(ProgressAnalytics.e1RMSeries(try rows(), exerciseID: pullupID, policy: .default).isEmpty,
                      "a bodyweight lift has no external e1RM")
    }

    func testWarmupSetsExcludedFromE1RMAndVolume() throws {
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            set("Bench Press", 95, 5, type: .warmup),     // warmup — must not count toward trends
            set("Bench Press", 135, 5, type: .working)
        ]))
        let benchID = try id("Bench Press")
        XCTAssertEqual(ProgressAnalytics.e1RMSeries(try rows(), exerciseID: benchID, policy: .default).first?.value ?? 0,
                       157.5, accuracy: 0.01, "only the working set's 135 contributes to e1RM")
        XCTAssertEqual(ProgressAnalytics.volumeSeries(try rows(), exerciseID: benchID, policy: .default).first?.value ?? 0,
                       675, accuracy: 0.01, "volume counts the working 135×5, not the warmup 95×5")
    }
}
