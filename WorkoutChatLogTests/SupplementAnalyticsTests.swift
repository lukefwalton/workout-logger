import XCTest
@testable import WorkoutChatLog

/// Pure trend math — no store, no UI. A fixed `today` and an explicit calendar make
/// the streak/adherence/grams-series deterministic.
final class SupplementAnalyticsTests: XCTestCase {

    private var calendar = Calendar(identifier: .gregorian)
    private let today = Date(timeIntervalSince1970: 1_800_000_000)   // a fixed reference day

    private func day(_ daysAgo: Int) -> String {
        SupplementDay.key(daysAgo: daysAgo, from: today, calendar: calendar)
    }

    private let creatine = Supplement(id: 1, name: "Creatine", isPreset: true, tracksGrams: false, sortOrder: 0)
    private let protein = Supplement(id: 2, name: "Protein", isPreset: true, tracksGrams: true, sortOrder: 1)

    func testAdherenceCountsDaysInWindowOnly() {
        let history = [
            SupplementIntake(supplementID: 1, day: day(0), grams: nil),
            SupplementIntake(supplementID: 1, day: day(5), grams: nil),
            SupplementIntake(supplementID: 1, day: day(40), grams: nil),   // outside a 30-day window
        ]
        let trend = SupplementAnalytics.trends(supplements: [creatine], history: history,
                                               today: today, windowDays: 30, calendar: calendar)[0]
        XCTAssertEqual(trend.daysTaken, 2)
        XCTAssertEqual(trend.windowDays, 30)
        XCTAssertEqual(trend.adherence, 2.0 / 30.0, accuracy: 1e-9)
    }

    func testCurrentStreakCountsConsecutiveDaysEndingToday() {
        let history = (0...3).map { SupplementIntake(supplementID: 1, day: day($0), grams: nil) }
            + [SupplementIntake(supplementID: 1, day: day(5), grams: nil)]   // gap at day(4)
        let trend = SupplementAnalytics.trends(supplements: [creatine], history: history,
                                               today: today, calendar: calendar)[0]
        XCTAssertEqual(trend.currentStreak, 4)
    }

    func testStreakStaysAliveWhenTodayNotYetChecked() {
        // Taken yesterday and the day before, but not today → streak still 2.
        let history = [
            SupplementIntake(supplementID: 1, day: day(1), grams: nil),
            SupplementIntake(supplementID: 1, day: day(2), grams: nil),
        ]
        let trend = SupplementAnalytics.trends(supplements: [creatine], history: history,
                                               today: today, calendar: calendar)[0]
        XCTAssertEqual(trend.currentStreak, 2)
    }

    func testStreakZeroWhenNeitherTodayNorYesterday() {
        let history = [SupplementIntake(supplementID: 1, day: day(3), grams: nil)]
        let trend = SupplementAnalytics.trends(supplements: [creatine], history: history,
                                               today: today, calendar: calendar)[0]
        XCTAssertEqual(trend.currentStreak, 0)
    }

    func testGramsSeriesIsWindowedSortedAndDropsZeroOrNil() {
        let history = [
            SupplementIntake(supplementID: 2, day: day(2), grams: 40),
            SupplementIntake(supplementID: 2, day: day(0), grams: 50),
            SupplementIntake(supplementID: 2, day: day(1), grams: nil),     // taken, no grams → excluded
            SupplementIntake(supplementID: 2, day: day(3), grams: 0),       // zero → excluded
            SupplementIntake(supplementID: 2, day: day(40), grams: 99),     // outside window → excluded
        ]
        let series = SupplementAnalytics.gramsSeries(supplementID: 2, history: history,
                                                     today: today, windowDays: 30, calendar: calendar)
        XCTAssertEqual(series.map(\.grams), [40, 50], "oldest first, only real grams within the window")
    }
}
