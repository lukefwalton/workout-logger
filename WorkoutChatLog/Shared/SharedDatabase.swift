import Foundation

/// The shared App Group. It lets the main app and the Home Screen widget (PR 12)
/// open the *same* on-device database file from their separate processes. The
/// identifier is duplicated in `project.yml` (each target's
/// `com.apple.security.application-groups` entitlement) because nothing can read a
/// build setting from Swift at compile time — the strings must stay in sync by hand.
enum AppGroup {
    static let identifier = "group.com.lukewalton.workoutchatlog"
}

/// Locates the shared SQLite file and parses the store's timestamps. Lives in the
/// **Shared** module (compiled into both the app and the widget targets) so the
/// read-only widget can find and read the same database **without** linking the
/// whole `WorkoutStore` write path.
enum SharedDatabase {
    enum StoreError: Error, CustomStringConvertible {
        /// The App Group container couldn't be resolved — a developer/signing
        /// problem (missing entitlement / provisioning), surfaced honestly rather
        /// than silently falling back to a private sandbox the widget can't reach.
        case containerUnavailable(String)

        var description: String {
            switch self {
            case .containerUnavailable(let id):
                return "App Group container unavailable for \"\(id)\". "
                     + "Check the com.apple.security.application-groups entitlement and provisioning profile."
            }
        }
    }

    /// The on-device database file inside the shared App Group container. Both the
    /// app (read/write) and the widget (read-only) resolve the same path here.
    ///
    /// **Backup strategy.** The file lives in the App Group container, which is
    /// included in the system's encrypted iCloud Backup by default (the app
    /// does **not** set `isExcludedFromBackup = true` on the URL). That covers
    /// the audit's "lose the phone, lose history" risk for users who have
    /// iCloud Backup enabled — Apple restores the file when they set up a new
    /// device. Users who prefer manual backup can use Settings → Export all
    /// workout data, then Restore from backup, which round-trips the JSON
    /// export through the same `WorkoutStore.importData` path.
    ///
    /// True live iCloud/CloudKit sync (multi-device, conflict resolution) is a
    /// separate larger feature deliberately out of scope for v1 — the local
    /// SQLite + manual export + system backup combination gives ownership and
    /// portability without taking on the sync surface.
    static func databaseURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) else {
            throw StoreError.containerUnavailable(AppGroup.identifier)
        }
        return container.appendingPathComponent("workout.sqlite")
    }

    /// Parse the store's fixed ISO8601 timestamps so the widget can read `ended_at`
    /// without importing `WorkoutStore`. Delegates to the canonical
    /// `WorkoutDateFormat` so the format string lives in exactly one place.
    static func date(_ text: String?) -> Date? { WorkoutDateFormat.date(text) }
}
