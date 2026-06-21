import Foundation
@testable import WorkoutChatLog

/// A scripted `RestTimerNotifier` for the rest-timer tests — never imports
/// `UserNotifications`. Models the in-context permission flow: `authorized` starts
/// false and flips true only if `grantsOnRequest` is set when authorization is
/// requested, mirroring a real prompt. Records calls so tests can assert the timer
/// prompts lazily and schedules only when granted.
final class FakeRestTimerNotifier: RestTimerNotifier {
    var authorized = false
    /// Whether a permission request would be granted (the user tapping "Allow").
    var grantsOnRequest = false

    private(set) var authorizationRequests = 0
    private(set) var scheduledCount = 0
    private(set) var cancelCount = 0
    private(set) var lastScheduledSeconds: TimeInterval?
    /// Tokens currently "pending" (scheduled and not yet cancelled), mirroring the real
    /// notifier's per-token requests so the token-scoped cancel race can be asserted.
    private(set) var pendingTokens: Set<String> = []

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        if grantsOnRequest { authorized = true }
        return authorized
    }

    func isAuthorized() async -> Bool { authorized }

    @discardableResult
    func scheduleRestEnd(after seconds: TimeInterval, token: String) async -> Bool {
        guard authorized, seconds > 0 else { return false }
        scheduledCount += 1
        lastScheduledSeconds = seconds
        pendingTokens.insert(token)
        return true
    }

    func cancelScheduledRestEnd(token: String) {
        cancelCount += 1
        pendingTokens.remove(token)
    }
}
