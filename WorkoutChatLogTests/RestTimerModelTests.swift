import XCTest
@testable import WorkoutChatLog

/// The rest timer's pure logic (spec §4): the countdown state machine, mm:ss
/// formatting, and the in-context permission flow — all with an injected clock and
/// a fake notifier, so nothing here touches `UserNotifications` or waits in real
/// time. The actual background-alert delivery is a device-acceptance step.
@MainActor
final class RestTimerModelTests: XCTestCase {

    private var clock: Date!
    private func now() -> Date { clock }

    override func setUp() {
        super.setUp()
        clock = Date(timeIntervalSince1970: 1_000_000)
    }

    private func makeModel(_ notifier: FakeRestTimerNotifier = FakeRestTimerNotifier()) -> RestTimerModel {
        RestTimerModel(notifier: notifier, selectedDuration: 90, now: { [unowned self] in self.clock })
    }

    // MARK: - mm:ss formatting

    func testMMSSFormatting() {
        XCTAssertEqual(RestTimerModel.mmss(90), "1:30")
        XCTAssertEqual(RestTimerModel.mmss(0), "0:00")
        XCTAssertEqual(RestTimerModel.mmss(5), "0:05")
        XCTAssertEqual(RestTimerModel.mmss(125), "2:05")
        XCTAssertEqual(RestTimerModel.mmss(-3), "0:00", "never a negative clock")
    }

    // MARK: - Countdown state machine

    func testStartBeginsRunningWithFullRemaining() {
        let model = makeModel()
        model.start(seconds: 90)
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.remainingSeconds, 90)
        XCTAssertEqual(model.display, "1:30")
    }

    func testTickCountsDownAndFinishesAtZero() {
        let model = makeModel()
        model.start(seconds: 90)

        clock = clock.addingTimeInterval(45)
        model.tick()
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.remainingSeconds, 45)

        clock = clock.addingTimeInterval(44)   // 89s elapsed total
        model.tick()
        XCTAssertEqual(model.phase, .running, "still running just before the end")
        XCTAssertEqual(model.remainingSeconds, 1)

        clock = clock.addingTimeInterval(1)    // 90s elapsed total
        model.tick()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.remainingSeconds, 0)
        XCTAssertEqual(model.display, "0:00")
    }

    func testTickPastEndClampsToFinished() {
        let model = makeModel()
        model.start(seconds: 60)
        clock = clock.addingTimeInterval(1000)
        model.tick()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.remainingSeconds, 0)
    }

    func testCancelReturnsToIdle() {
        let notifier = FakeRestTimerNotifier()
        let model = makeModel(notifier)
        model.start(seconds: 90)
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.remainingSeconds, 0)
        XCTAssertEqual(notifier.cancelCount, 1, "a pending alert is cancelled too")
    }

    func testZeroDurationDoesNotStart() {
        let model = makeModel()
        model.start(seconds: 0)
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: - In-context permission (never at launch)

    func testStartRequestsAuthorizationInContextThenSchedulesWhenGranted() async {
        let notifier = FakeRestTimerNotifier()
        notifier.grantsOnRequest = true
        let model = makeModel(notifier)

        XCTAssertEqual(notifier.authorizationRequests, 0, "nothing is requested before the first start")
        model.start(seconds: 120)
        await model.drainNotificationTask()

        XCTAssertEqual(notifier.authorizationRequests, 1, "permission is prompted in context, on first start")
        XCTAssertEqual(notifier.scheduledCount, 1, "granted → a background alert is scheduled")
        XCTAssertEqual(notifier.lastScheduledSeconds, 120)
    }

    func testDeniedPermissionStillRunsCountdownButSchedulesNothing() async {
        let notifier = FakeRestTimerNotifier()
        notifier.grantsOnRequest = false   // user taps "Don't Allow"
        let model = makeModel(notifier)

        model.start(seconds: 90)
        await model.drainNotificationTask()

        XCTAssertEqual(model.phase, .running, "the in-app countdown runs regardless of permission")
        XCTAssertEqual(notifier.authorizationRequests, 1)
        XCTAssertEqual(notifier.scheduledCount, 0, "denied → no background alert")
    }

    func testAlreadyAuthorizedSchedulesWithoutReprompting() async {
        let notifier = FakeRestTimerNotifier()
        notifier.authorized = true
        let model = makeModel(notifier)

        model.start(seconds: 60)
        await model.drainNotificationTask()

        XCTAssertEqual(notifier.authorizationRequests, 0, "no re-prompt when already authorized")
        XCTAssertEqual(notifier.scheduledCount, 1)
    }

    func testCancelWhileTaskInFlightDoesNotScheduleStaleAlert() async {
        // The notifier grants only when asked; if the user cancels before the prompt
        // resolves, the in-flight task must not schedule an alert for a dead timer.
        let notifier = FakeRestTimerNotifier()
        notifier.grantsOnRequest = true
        let model = makeModel(notifier)

        model.start(seconds: 90)
        model.cancel()                      // bumps the generation before the task runs
        await model.drainNotificationTask()

        XCTAssertEqual(notifier.scheduledCount, 0, "a cancelled timer schedules nothing")
        XCTAssertEqual(model.phase, .idle)
    }

    func testRestartSupersedesPreviousTimerSchedule() async {
        let notifier = FakeRestTimerNotifier()
        notifier.authorized = true
        let model = makeModel(notifier)

        model.start(seconds: 60)
        model.start(seconds: 120)           // restart before draining the first task
        await model.drainNotificationTask()

        // Only the current timer schedules; the last scheduled duration is the restart's.
        XCTAssertEqual(notifier.lastScheduledSeconds, 120)
    }

    func testRestartCancelsThePreviousPendingNotificationImmediately() async {
        // Restarting near the old end must drop the previous OS notification right away
        // (synchronously in start()), not just eventually via the async reschedule —
        // otherwise a stale "rest's over" could fire in the gap.
        let notifier = FakeRestTimerNotifier()
        notifier.authorized = true
        let model = makeModel(notifier)

        model.start(seconds: 60)
        await model.drainNotificationTask()       // first schedule lands
        XCTAssertEqual(notifier.scheduledCount, 1)

        model.start(seconds: 90)                  // restart
        XCTAssertGreaterThanOrEqual(notifier.cancelCount, 1, "the old pending alert is cancelled synchronously")
        await model.drainNotificationTask()
        XCTAssertEqual(notifier.lastScheduledSeconds, 90, "only the new timer's alert remains")
    }

    func testRestartSynchronouslyRetiresTheAlreadyScheduledAlertById() async {
        // Hard guarantee: by the time start() returns on a restart, the previous timer's
        // already-scheduled request is gone (cancelled by exact id, synchronously) — not
        // pending removal via an async enumeration. So a near-expiry old alert can't fire.
        let notifier = FakeRestTimerNotifier()
        notifier.authorized = true
        let model = makeModel(notifier)

        model.start(seconds: 60)
        await model.drainNotificationTask()
        let firstToken = try! XCTUnwrap(notifier.pendingTokens.first)

        model.start(seconds: 90)   // restart
        XCTAssertFalse(notifier.pendingTokens.contains(firstToken),
                       "the old request is removed synchronously, before start() returns")
        await model.drainNotificationTask()
        XCTAssertEqual(notifier.pendingTokens.count, 1, "only the new timer's alert remains")
    }

    func testFinishingForegroundedRetiresTheRedundantPendingAlert() async {
        // When the in-app countdown reaches .finished while foregrounded, the pending OS
        // alert (same instant) is redundant and is retired, so there's no double buzz.
        let notifier = FakeRestTimerNotifier()
        notifier.authorized = true
        let model = makeModel(notifier)

        model.start(seconds: 60)
        await model.drainNotificationTask()
        XCTAssertEqual(notifier.pendingTokens.count, 1)

        clock = clock.addingTimeInterval(60)
        model.tick()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertTrue(notifier.pendingTokens.isEmpty, "the redundant background alert is cleared on finish")
    }

    func testTokenScopedCancelRemovesOnlyThatRequest() {
        // The invariant that closes the mid-await race: a superseded task cancels by its
        // own token, so it can never delete a newer timer's pending alert.
        let notifier = FakeRestTimerNotifier()
        notifier.authorized = true
        let staleToken = "A", liveToken = "B"
        let exp = expectation(description: "both scheduled")
        Task {
            _ = await notifier.scheduleRestEnd(after: 60, token: staleToken)
            _ = await notifier.scheduleRestEnd(after: 90, token: liveToken)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)

        notifier.cancelScheduledRestEnd(token: staleToken)   // stale task retracts itself
        XCTAssertEqual(notifier.pendingTokens, [liveToken], "the live timer's alert is untouched")
    }

    func testSlowPermissionPromptSchedulesAgainstTheRealEndNotFullDuration() async {
        // First-run grant: the prompt "takes" 20s (the clock advances before the task
        // schedules). The alert must be scheduled for the *remaining* 70s, not the full
        // 90s, so it lands when rest actually ends rather than 20s late.
        let notifier = FakeRestTimerNotifier()
        notifier.grantsOnRequest = true
        let model = makeModel(notifier)

        model.start(seconds: 90)
        clock = clock.addingTimeInterval(20)   // user spent 20s on the permission prompt
        await model.drainNotificationTask()

        XCTAssertEqual(notifier.scheduledCount, 1)
        XCTAssertEqual(notifier.lastScheduledSeconds, 70, "scheduled against the absolute end time")
    }

    // MARK: - Preferences

    func testResolvedDefaultFallsBackForUnsetOrUnknown() {
        XCTAssertEqual(RestTimerPreferences.resolvedDefault(0), RestTimerPreferences.defaultDurationSeconds)
        XCTAssertEqual(RestTimerPreferences.resolvedDefault(120), 120)
        XCTAssertEqual(RestTimerPreferences.resolvedDefault(37),
                       RestTimerPreferences.defaultDurationSeconds, "an off-menu value falls back")
    }
}
