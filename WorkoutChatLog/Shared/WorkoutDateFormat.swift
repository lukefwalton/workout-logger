import Foundation

/// The single canonical ISO8601 parser/formatter for the store's timestamps.
/// Lives in **Shared** so the widget (read-only) and the app (read/write) both
/// see the same format — and so the formatter is allocated exactly once per
/// process instead of three times (the previous spread across `WorkoutStore`,
/// `SharedDatabase`, and `HistoryModel`).
///
/// `ISO8601DateFormatter` is documented thread-safe for `string(from:)`/
/// `date(from:)` once configured, so a single `nonisolated static let` is the
/// right shape. (An earlier review note about a "DateFormatter concurrency
/// hazard" applied to `DateFormatter`, not this type.)
enum WorkoutDateFormat {
    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(_ date: Date) -> String { iso.string(from: date) }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return iso.date(from: text)
    }
}
