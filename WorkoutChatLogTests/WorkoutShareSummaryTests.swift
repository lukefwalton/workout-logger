import XCTest
@testable import WorkoutChatLog

/// Golden tests for `WorkoutShareSummary.aiPrompt(...)` — the deterministic,
/// on-device Markdown the "AI share" feature produces. This is a pure transform
/// over `WorkoutSetHistoryRow` (no database), so the output is asserted exactly:
/// the table shape, the optional Notes column and its escaping, and the trend
/// summary's math, ordering, and mixed-unit / flat edge cases.
final class WorkoutShareSummaryTests: XCTestCase {

    // MARK: - Builders

    private func ext(_ weight: Double, _ unit: WeightUnit = .lb) -> WorkoutLoad {
        WorkoutLoad.stored(kind: .external, weight: weight, unit: unit)
    }

    private func row(date: String, exercise: String, setIndex: Int, load: WorkoutLoad, reps: Int,
                     rir: Int? = nil, type: SetType = .working, notes: String? = nil,
                     sessionID: Int64 = 1, setID: Int64 = 1) -> WorkoutSetHistoryRow {
        WorkoutSetHistoryRow(sessionID: sessionID, sessionName: nil, sessionNotes: nil, startedAt: date,
                             sessionEndedAt: nil, sessionFeel: nil, sessionIsDeload: false,
                             setID: setID, exerciseID: 1, exerciseName: exercise, setIndex: setIndex,
                             setType: type, load: load, reps: reps, rir: rir, notes: notes,
                             sourceText: nil, primaryMuscle: nil)
    }

    // MARK: - Table

    func testEmptyWindowReportsNoDataWithTheWindow() {
        let out = WorkoutShareSummary.aiPrompt(rows: [], days: 30)
        XCTAssertEqual(out,
            "Here is my recent training log. I do not have workout sets in this export window yet."
            + "\n\nData window: last 30 days")
    }

    func testRendersOneSetAsAMarkdownTableRow() {
        let out = WorkoutShareSummary.aiPrompt(
            rows: [row(date: "2026-06-01", exercise: "Bench Press", setIndex: 1, load: ext(135), reps: 8, rir: 2)],
            days: 7)
        XCTAssertEqual(out, [
            "Here is my recent training log.",
            "",
            "Data window: last 7 days",
            "Format: one row per logged set. This payload was prepared locally; I chose to share it.",
            "",
            "| Date | Exercise | Set | Load | Reps | RIR | Type |",
            "| --- | --- | ---: | --- | ---: | --- | --- |",
            "| 2026-06-01 | Bench Press | 1 | 135 lb | 8 | 2 | working |",
        ].joined(separator: "\n"))
    }

    func testNotesColumnIsAddedAndCellsAreEscaped() {
        // includeNotes adds the column + its separator dash; a missing RIR is a blank
        // cell; and a note's pipes/newlines are escaped so the table can't break.
        let out = WorkoutShareSummary.aiPrompt(
            rows: [row(date: "2026-06-02", exercise: "Pull-Up", setIndex: 3,
                       load: WorkoutLoad.stored(kind: .bodyweight, weight: 0, unit: .lb),
                       reps: 10, rir: nil, notes: "strong | left elbow\ntwinge")],
            days: 30, includeNotes: true)
        XCTAssertEqual(out, [
            "Here is my recent training log.",
            "",
            "Data window: last 30 days",
            "Format: one row per logged set. This payload was prepared locally; I chose to share it.",
            "",
            "| Date | Exercise | Set | Load | Reps | RIR | Type | Notes |",
            "| --- | --- | ---: | --- | ---: | --- | --- | --- |",
            "| 2026-06-02 | Pull-Up | 3 | BW | 10 |  | working | strong \\| left elbow twinge |",
        ].joined(separator: "\n"))
    }

    // MARK: - Trend summary

    func testTrendSummaryComputesAveragesAndRisingLoadTrend() {
        // Two sessions of Squat, 135→145 lb. Averages: load 140, reps 5, RIR 1.5;
        // the load trend compares the earlier half (135) to the later half (145).
        let out = WorkoutShareSummary.aiPrompt(rows: [
            row(date: "2026-06-08", exercise: "Squat", setIndex: 1, load: ext(145), reps: 5, rir: 1, sessionID: 200, setID: 4),
            row(date: "2026-06-08", exercise: "Squat", setIndex: 2, load: ext(145), reps: 5, rir: 1, sessionID: 200, setID: 3),
            row(date: "2026-06-01", exercise: "Squat", setIndex: 1, load: ext(135), reps: 5, rir: 2, sessionID: 100, setID: 2),
            row(date: "2026-06-01", exercise: "Squat", setIndex: 2, load: ext(135), reps: 5, rir: 2, sessionID: 100, setID: 1),
        ], days: 30, includeTrends: true)
        XCTAssertEqual(out, [
            "Here is my recent training log.",
            "",
            "Data window: last 30 days",
            "Format: one row per logged set. This payload was prepared locally; I chose to share it.",
            "",
            "## Deterministic Trend Summary",
            "",
            "| Exercise | Sets | Sessions | Avg Load | Avg Reps | Avg RIR | Load Trend |",
            "| --- | ---: | ---: | --- | ---: | ---: | --- |",
            "| Squat | 4 | 2 | 140 lb | 5 | 1.5 | +10 lb |",
            "",
            "| Date | Exercise | Set | Load | Reps | RIR | Type |",
            "| --- | --- | ---: | --- | ---: | --- | --- |",
            "| 2026-06-08 | Squat | 1 | 145 lb | 5 | 1 | working |",
            "| 2026-06-08 | Squat | 2 | 145 lb | 5 | 1 | working |",
            "| 2026-06-01 | Squat | 1 | 135 lb | 5 | 2 | working |",
            "| 2026-06-01 | Squat | 2 | 135 lb | 5 | 2 | working |",
        ].joined(separator: "\n"))
    }

    func testTrendOmitsLoadAcrossMixedUnits() {
        // lb and kg in the same exercise must not be averaged or trended — the app
        // never silently converts units.
        let out = WorkoutShareSummary.aiPrompt(rows: [
            row(date: "2026-06-03", exercise: "Deadlift", setIndex: 1, load: ext(225, .lb), reps: 3, rir: 1, sessionID: 300, setID: 10),
            row(date: "2026-06-03", exercise: "Deadlift", setIndex: 2, load: ext(100, .kg), reps: 3, rir: 1, sessionID: 300, setID: 11),
        ], days: 30, includeTrends: true)
        XCTAssertTrue(out.contains("| Deadlift | 2 | 1 | n/a | 3 | 1 | (mixed units — trend omitted) |"),
                      "mixed units yield n/a load and an explicit omitted-trend note:\n\(out)")
    }

    func testTrendReadsFlatWhenLoadIsUnchanged() {
        let out = WorkoutShareSummary.aiPrompt(rows: [
            row(date: "2026-06-08", exercise: "OHP", setIndex: 1, load: ext(95), reps: 5, sessionID: 2, setID: 2),
            row(date: "2026-06-01", exercise: "OHP", setIndex: 1, load: ext(95), reps: 5, sessionID: 1, setID: 1),
        ], days: 30, includeTrends: true)
        XCTAssertTrue(out.contains("| OHP | 2 | 2 | 95 lb | 5 | n/a | flat |"),
                      "equal early/late loads read as flat (not +0), and absent RIR is n/a:\n\(out)")
    }

    func testTrendRowsSortCaseInsensitively() {
        // 'arnold press' (lowercase) must sort before 'Bench Press' — a case-sensitive
        // sort would put uppercase 'B' first.
        let out = WorkoutShareSummary.aiPrompt(rows: [
            row(date: "2026-06-01", exercise: "Bench Press", setIndex: 1, load: ext(135), reps: 8, sessionID: 1, setID: 1),
            row(date: "2026-06-01", exercise: "arnold press", setIndex: 1, load: ext(40), reps: 10, sessionID: 1, setID: 2),
        ], days: 30, includeTrends: true)
        guard let arnold = out.range(of: "| arnold press |"),
              let bench = out.range(of: "| Bench Press |") else {
            return XCTFail("both exercises should appear in the trend section:\n\(out)")
        }
        XCTAssertLessThan(arnold.lowerBound, bench.lowerBound,
                          "trend rows sort case-insensitively")
    }
}
