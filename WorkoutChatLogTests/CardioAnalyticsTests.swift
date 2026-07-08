import XCTest
@testable import WorkoutChatLog

/// CardioAnalytics is pure functions over `[CardioEntry]`, so these tests run on
/// synthetic entries with a fixed `today` — fully deterministic, no database.
final class CardioAnalyticsTests: XCTestCase {

    // Thursday 2026-06-18 12:00:00 UTC — mid-week so ± a couple of days stays in
    // the same ISO week (in any test-runner timezone) and ±7 lands in the neighbors.
    private let today = Date(timeIntervalSince1970: 1_781_784_000)

    private func entry(_ activity: String, seconds: Int? = nil, distance: Double? = nil,
                       unit: CardioDistanceUnit? = nil, daysAgo: Double, id: Int64 = 0) -> CardioEntry {
        CardioEntry(id: id, activity: activity, durationSeconds: seconds,
                    distance: distance, distanceUnit: unit, notes: nil, sourceText: nil,
                    loggedAt: today.addingTimeInterval(-daysAgo * 86_400))
    }

    // MARK: - Weekly minutes

    func testBoutsInTheSameISOWeekSumIntoOneBar() {
        let weekly = CardioAnalytics.weeklyMinutes(
            entries: [entry("Run", seconds: 1800, daysAgo: 0),
                      entry("Run", seconds: 600, daysAgo: 1)],
            today: today)
        XCTAssertEqual(weekly.count, 1)
        XCTAssertEqual(weekly[0].activity, "Run")
        XCTAssertEqual(weekly[0].minutes, 40, accuracy: 0.001)
    }

    func testAdjacentWeeksSplitIntoSeparateBars() {
        let weekly = CardioAnalytics.weeklyMinutes(
            entries: [entry("Run", seconds: 1800, daysAgo: 0),
                      entry("Run", seconds: 1800, daysAgo: 7)],
            today: today)
        XCTAssertEqual(weekly.count, 2, "seven days apart from mid-week is two ISO weeks")
        XCTAssertLessThan(weekly[0].weekStart, weekly[1].weekStart, "sorted chronologically")
        XCTAssertEqual(weekly.map(\.minutes), [30, 30])
    }

    func testActivitiesStackSeparatelyWithinAWeek() {
        let weekly = CardioAnalytics.weeklyMinutes(
            entries: [entry("Run", seconds: 1800, daysAgo: 0),
                      entry("Cycling", seconds: 2400, daysAgo: 1)],
            today: today)
        XCTAssertEqual(weekly.count, 2)
        XCTAssertEqual(weekly.map(\.activity), ["Cycling", "Run"], "same week sorts by activity name")
    }

    func testDurationlessBoutsAreExcludedFromMinutes() {
        let weekly = CardioAnalytics.weeklyMinutes(
            entries: [entry("Run", distance: 5, unit: .km, daysAgo: 0)],
            today: today)
        XCTAssertTrue(weekly.isEmpty, "a distance-only bout contributes no fabricated minutes")
    }

    func testGroupingIsByVerbatimActivityString() {
        // Analytics never fuzzy-merge: distinct stored strings stay distinct series.
        let weekly = CardioAnalytics.weeklyMinutes(
            entries: [entry("Run", seconds: 600, daysAgo: 0),
                      entry("run", seconds: 600, daysAgo: 0)],
            today: today)
        XCTAssertEqual(weekly.map(\.activity).sorted(), ["Run", "run"])
    }

    func testWindowExcludesOldEntries() {
        let weekly = CardioAnalytics.weeklyMinutes(
            entries: [entry("Run", seconds: 1800, daysAgo: 0),
                      entry("Run", seconds: 1800, daysAgo: 45)],
            today: today, windowDays: 30)
        XCTAssertEqual(weekly.count, 1)
        XCTAssertEqual(weekly[0].minutes, 30, accuracy: 0.001, "the 45-day-old bout is out of window")
    }

    // MARK: - Activity summaries

    func testSummariesCountEveryBoutButSumOnlyRealMetrics() {
        let summaries = CardioAnalytics.activitySummaries(
            entries: [entry("Run", seconds: 1800, distance: 3.1, unit: .mi, daysAgo: 0),
                      entry("Run", daysAgo: 1),                       // metric-less "logged" bout
                      entry("Run", seconds: 600, daysAgo: 2)],
            today: today)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].bouts, 3, "metric-less bouts still count as bouts")
        XCTAssertEqual(summaries[0].totalSeconds, 2400)
        XCTAssertEqual(summaries[0].distanceByUnit, [.mi: 3.1])
    }

    func testMixedUnitsAreNeverConverted() {
        let summaries = CardioAnalytics.activitySummaries(
            entries: [entry("Run", distance: 5, unit: .km, daysAgo: 0),
                      entry("Run", distance: 3.1, unit: .mi, daysAgo: 1),
                      entry("Run", distance: 2, unit: .km, daysAgo: 2)],
            today: today)
        XCTAssertEqual(summaries[0].distanceByUnit, [.km: 7, .mi: 3.1],
                       "distances stay in their logged units — two keys, no conversion")
    }

    func testSummariesSortMostDoneFirst() {
        let summaries = CardioAnalytics.activitySummaries(
            entries: [entry("Walk", seconds: 600, daysAgo: 0),
                      entry("Run", seconds: 600, daysAgo: 1),
                      entry("Run", seconds: 600, daysAgo: 2)],
            today: today)
        XCTAssertEqual(summaries.map(\.activity), ["Run", "Walk"])
    }

    // MARK: - Detail line (rendered by CardioTrendsView)

    func testDetailLineJoinsOnlyPresentParts() {
        let summary = CardioAnalytics.ActivitySummary(
            activity: "Run", bouts: 6, totalSeconds: 11_400, distanceByUnit: [.mi: 12, .km: 5])
        XCTAssertEqual(CardioTrendsView.detail(for: summary), "6 bouts · 3h 10m · 12 mi · 5 km")

        let bare = CardioAnalytics.ActivitySummary(
            activity: "Cardio", bouts: 1, totalSeconds: 0, distanceByUnit: [:])
        XCTAssertEqual(CardioTrendsView.detail(for: bare), "1 bout")
    }

    func testDetailLineRoundsAccumulatedFloats() {
        // 1.1 + 2.2 is 3.3000000000000003 in binary — the summed total must
        // render rounded, never with float noise.
        let summed = CardioAnalytics.ActivitySummary(
            activity: "Run", bouts: 2, totalSeconds: 0, distanceByUnit: [.mi: 1.1 + 2.2])
        XCTAssertEqual(CardioTrendsView.detail(for: summed), "2 bouts · 3.3 mi")
    }
}
