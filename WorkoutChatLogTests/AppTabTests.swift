import XCTest
@testable import WorkoutChatLog

/// Thin by design: most of the swipe navigation is native composition that needs
/// a device to judge. What's worth pinning is the invariant a refactor could
/// silently break — the tab order *is* the left-to-right page order, so the bar
/// and the swipe stay in agreement.
final class AppTabTests: XCTestCase {

    func testSwipeOrderIsStable() {
        XCTAssertEqual(AppTab.allCases, [.today, .history, .progress, .settings])
    }

    func testIdsMatchPageOrder() {
        XCTAssertEqual(AppTab.allCases.map(\.id), [0, 1, 2, 3])
    }

    func testEveryTabHasTitleAndIcon() {
        for tab in AppTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.icon.isEmpty)
        }
    }
}
