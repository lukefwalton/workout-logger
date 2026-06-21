import XCTest
@testable import WorkoutChatLog

/// PR 10 — the toggle/permission gating in `HealthWorkoutCoordinator` and the
/// bodyweight fallback, driven by a fake `HealthService` (no HealthKit import).
final class HealthWorkoutTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "wcl-health-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func coordinator(_ service: FakeHealthService) -> HealthWorkoutCoordinator {
        HealthWorkoutCoordinator(service: service, defaults: defaults)
    }

    private func enableSaving() {
        defaults.set(true, forKey: HealthPreferences.saveWorkoutsToHealthKey)
    }

    private var window: (start: Date, end: Date) {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return (start, start.addingTimeInterval(3600))
    }

    // MARK: - Workout write gating

    func testNoWorkoutWrittenWhenToggleOff() async {
        let service = FakeHealthService()             // authorized, available
        let wrote = await coordinator(service).recordFinishedSession(start: window.start, end: window.end)
        XCTAssertFalse(wrote)
        XCTAssertEqual(service.workoutWrites, 0, "default-off toggle means no write even with permission")
    }

    func testOneWorkoutWrittenWhenEnabledAndAuthorized() async {
        enableSaving()
        let service = FakeHealthService()
        let wrote = await coordinator(service).recordFinishedSession(start: window.start, end: window.end)
        XCTAssertTrue(wrote)
        XCTAssertEqual(service.workoutWrites, 1)
        XCTAssertEqual(service.lastWorkoutBounds?.start, window.start)
        XCTAssertEqual(service.lastWorkoutBounds?.end, window.end)
    }

    func testNoWorkoutWrittenWhenEnabledButPermissionDenied() async {
        enableSaving()
        let service = FakeHealthService()
        service.authorized = false
        let wrote = await coordinator(service).recordFinishedSession(start: window.start, end: window.end)
        XCTAssertFalse(wrote)
        XCTAssertEqual(service.workoutWrites, 0)
    }

    func testNoWorkoutWrittenForDegenerateBounds() async {
        enableSaving()
        let service = FakeHealthService()
        let wrote = await coordinator(service).recordFinishedSession(start: window.end, end: window.start)
        XCTAssertFalse(wrote, "end before start must never write a workout")
        XCTAssertEqual(service.workoutWrites, 0)
    }

    // MARK: - Bodyweight fallback

    func testBodyweightPrefersHealthKit() async {
        let service = FakeHealthService()
        service.bodyweightKg = 81.5
        defaults.set(70.0, forKey: HealthPreferences.manualBodyweightKgKey)
        let value = await coordinator(service).bodyweightKilograms()
        XCTAssertEqual(value, 81.5, "HealthKit bodyweight wins when present")
    }

    func testBodyweightFallsBackToManualWhenHealthKitUnavailable() async {
        let service = FakeHealthService()
        service.bodyweightKg = nil
        defaults.set(72.0, forKey: HealthPreferences.manualBodyweightKgKey)
        let value = await coordinator(service).bodyweightKilograms()
        XCTAssertEqual(value, 72.0, "manual field is the fallback")
    }

    func testBodyweightNilWhenNeitherAvailable() async {
        let service = FakeHealthService()
        service.bodyweightKg = nil
        let value = await coordinator(service).bodyweightKilograms()
        XCTAssertNil(value, "never invent a bodyweight")
    }

    func testRequestAuthorizationForwardsToService() async {
        let service = FakeHealthService()
        _ = await coordinator(service).requestAuthorization()
        XCTAssertEqual(service.authorizationRequests, 1)
    }

    func testRequestAuthorizationReflectsWorkoutShareGrant() async {
        let grantedResult = await coordinator(FakeHealthService()).requestAuthorization()
        XCTAssertTrue(grantedResult)

        let denied = FakeHealthService()
        denied.authorized = false
        let deniedResult = await coordinator(denied).requestAuthorization()
        XCTAssertFalse(deniedResult, "a denied workout-share must report false so Settings can revert the toggle")
    }
}
