import XCTest
@testable import WorkoutChatLog

/// Pure formatting helpers on `TodayView` — the compact "last time" set string
/// (§4). No SwiftUI rendering; just the string math.
final class TodayViewFormattingTests: XCTestCase {

    private func external(_ weight: Double, _ reps: Int, unit: WeightUnit = .lb) -> LastTimeSet {
        LastTimeSet(load: WorkoutLoad.stored(kind: .external, weight: weight, unit: unit), reps: reps)
    }

    func testLastTimeSummaryListsLoadByRepsWithUnit() {
        let summary = TodayView.lastTimeSummary([external(135, 8), external(135, 8), external(130, 6)])
        XCTAssertEqual(summary, "135 lb×8, 135 lb×8, 130 lb×6")
    }

    func testLastTimeSummaryCarriesKgUnit() {
        XCTAssertEqual(TodayView.lastTimeSummary([external(100, 5, unit: .kg)]), "100 kg×5",
                       "unit is shown since lb/kg histories are distinct")
    }

    func testLastTimeSummaryUsesBWForBodyweight() {
        let bw = LastTimeSet(load: WorkoutLoad.stored(kind: .bodyweight, weight: 0, unit: .lb), reps: 12)
        XCTAssertEqual(TodayView.lastTimeSummary([bw]), "BW×12", "loadless bodyweight has no unit")
    }

    func testLastTimeSummaryPreservesLoadKindSemantics() {
        // bodyweight-plus and assisted must not flatten to a plain weight×reps that
        // would imply a barbell load the user never lifted — and they carry the unit.
        let plus = LastTimeSet(load: WorkoutLoad.stored(kind: .bodyweightPlus, weight: 25, unit: .lb), reps: 8)
        XCTAssertEqual(TodayView.lastTimeSummary([plus]), "BW+25 lb×8")
        let assisted = LastTimeSet(load: WorkoutLoad.stored(kind: .assisted, weight: 30, unit: .kg), reps: 6)
        XCTAssertEqual(TodayView.lastTimeSummary([assisted]), "asst 30 kg×6")
        let unspecified = LastTimeSet(load: WorkoutLoad.stored(kind: .unspecified, weight: 0, unit: .lb), reps: 10)
        XCTAssertEqual(TodayView.lastTimeSummary([unspecified]), "—×10")
    }

    func testLastTimeSummaryFormatsWeightWithUnit() {
        XCTAssertEqual(TodayView.lastTimeSummary([external(225, 5)]), "225 lb×5")
        XCTAssertEqual(TodayView.lastTimeSummary([external(102.5, 5, unit: .kg)]), "102.5 kg×5",
                       "fractional plates keep their decimal, with the unit")
    }

    func testRelativeDayProducesAPastPhrase() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 3600)
        // Locale-dependent exact wording, but it must read as past and mention days.
        let phrase = TodayView.relativeDay(sixDaysAgo, now: now).lowercased()
        XCTAssertTrue(phrase.contains("day"), "relative phrase mentions days: \(phrase)")
        XCTAssertTrue(phrase.contains("ago") || phrase.contains("6"), "reads as past: \(phrase)")
    }
}
