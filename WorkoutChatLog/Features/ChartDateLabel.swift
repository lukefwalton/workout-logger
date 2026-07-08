import Foundation

/// Cached medium-style date formatter for per-mark chart accessibility labels
/// (VoiceOver reads each datapoint with its date + value). One shared instance
/// so the Progress charts don't allocate a DateFormatter per mark — the same
/// no-per-row-allocation rule the history rows follow.
enum ChartDateLabel {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
}
