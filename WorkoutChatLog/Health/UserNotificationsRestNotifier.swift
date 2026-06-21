#if canImport(UserNotifications)
import Foundation
import os
import UserNotifications

/// The real rest-end notifier (spec §4). The entire file is wrapped in
/// `#if canImport(UserNotifications)` so not one `UNUserNotificationCenter` /
/// `UNMutableNotificationContent` symbol leaks into always-compiled code; callers
/// only ever see the `RestTimerNotifier` protocol, and tests use a fake.
///
/// NOT COMPILED HERE (Linux, no UserNotifications SDK) and the actual delivery is a
/// device-acceptance step — the symbol names below must be verified in Xcode. The
/// pure countdown/formatting logic in `RestTimerModel` is what's unit-tested here.
///
/// Doctrine (App Review): authorization is requested in context (first timer start),
/// never at launch. A denied permission only suppresses the background alert; the
/// in-app countdown still runs.
struct UserNotificationsRestNotifier: RestTimerNotifier {
    /// Identifier prefix for rest-end requests. Each scheduled alert appends its
    /// per-start token, so a superseded task cancels only its own request, while
    /// "cancel all" can match every rest-end request by prefix.
    private static let identifierPrefix = "workoutchatlog.restTimer.end."

    /// Failures here are survivable (the rest timer just doesn't post a background
    /// alert), so they collapse to `false` — but a *real* `UNUserNotificationCenter`
    /// failure must not be indistinguishable from "notifications were declined" in a
    /// device report. Log to the unified log (visible in Console/`log`, not only a
    /// DEBUG `print`), mirroring `HealthKitService`. A notification error carries no
    /// user content, so the description is safe to log `.public`.
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "WorkoutChatLog",
                             category: "RestTimer")

    private var center: UNUserNotificationCenter { .current() }

    private static func identifier(for token: String) -> String { identifierPrefix + token }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // Distinct from the user tapping "Don't Allow" (which returns false without
            // throwing) — this is the system failing the request, worth surfacing.
            log.error("authorization request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    @discardableResult
    func scheduleRestEnd(after seconds: TimeInterval, token: String) async -> Bool {
        guard seconds > 0 else { return false }
        guard await isAuthorized() else {
            // Expected when the user declined — log at `.info` so it's available for
            // "why didn't I get an alert?" reports without being noise at `.error`.
            log.info("rest-end alert skipped: notifications not authorized")
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = "Rest's over"
        content.body = "Time for your next set."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: Self.identifier(for: token),
                                            content: content, trigger: trigger)
        do {
            try await center.add(request)
            return true
        } catch {
            // Authorized but the OS rejected the request (e.g. pending-request limit) —
            // a real failure that would otherwise look identical to "no alert happened."
            log.error("scheduling rest-end alert failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func cancelScheduledRestEnd(token: String) {
        // Synchronous removal by exact id — no enumeration — so stop/restart closes the
        // already-scheduled-alert window immediately.
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(for: token)])
    }
}
#endif
