import XCTest
@testable import WorkoutChatLog

/// The Shared cardio display helpers (CardioDisplay.swift) are compiled into
/// both the app and the widget target. The icon lookup derives from
/// `CardioActivity` by display name, so these tests pin the lookup contract
/// (every canonical display resolves, matching is case-insensitive, free text
/// falls back) and the formatting edges the widget renders through.
final class CardioDisplayTests: XCTestCase {

    // MARK: - Icon lookup

    func testEveryCanonicalDisplayNameResolvesToItsIcon() {
        for activity in CardioActivity.allCases {
            XCTAssertEqual(CardioActivityIcon.symbol(forActivity: activity.display), activity.icon,
                           "display-name lookup broke for \(activity.display)")
        }
    }

    func testIconMatchIsCaseInsensitive() {
        XCTAssertEqual(CardioActivityIcon.symbol(forActivity: "run"), CardioActivity.run.icon)
        XCTAssertEqual(CardioActivityIcon.symbol(forActivity: "CYCLING"), CardioActivity.cycle.icon)
    }

    func testFreeTextActivityFallsBackToGenericHeart() {
        XCTAssertEqual(CardioActivityIcon.symbol(forActivity: "Jazzercise"), "heart.circle.fill")
        XCTAssertEqual(CardioActivityIcon.symbol(forActivity: ""), "heart.circle.fill")
    }

    // MARK: - CardioFormat edges (pinned here since the widget renders through it)

    func testDurationFormatting() {
        XCTAssertEqual(CardioFormat.duration(3661), "1h 01m")
        XCTAssertEqual(CardioFormat.duration(3600), "1h")
        XCTAssertEqual(CardioFormat.duration(1800), "30 min")
        XCTAssertEqual(CardioFormat.duration(90), "1m 30s")
        XCTAssertEqual(CardioFormat.duration(45), "45s")
        XCTAssertNil(CardioFormat.duration(0))
        XCTAssertNil(CardioFormat.duration(nil))
    }

    func testDistanceFormatting() {
        XCTAssertEqual(CardioFormat.distance(5, unit: .km), "5 km")
        XCTAssertEqual(CardioFormat.distance(3.1, unit: .mi), "3.1 mi")
        XCTAssertEqual(CardioFormat.distance(1000, unit: .m), "1000 m")
        XCTAssertNil(CardioFormat.distance(5, unit: nil), "a distance without a unit renders nothing")
        XCTAssertNil(CardioFormat.distance(nil, unit: .km))
    }

    func testSummaryNeverEmpty() {
        XCTAssertEqual(CardioFormat.summary(durationSeconds: 1800, distance: 5, distanceUnit: .km), "30 min · 5 km")
        XCTAssertEqual(CardioFormat.summary(durationSeconds: nil, distance: 5, distanceUnit: .km), "5 km")
        XCTAssertEqual(CardioFormat.summary(durationSeconds: nil, distance: nil, distanceUnit: nil), "logged")
    }
}
