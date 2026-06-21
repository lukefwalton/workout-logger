import Foundation

/// A configured supplement (Creatine, Protein, or a user custom). Identity is the
/// `id` rowid; presets can't be removed; `tracksGrams` drives the optional grams
/// field (Protein) vs. a plain checkbox.
struct Supplement: Identifiable, Equatable {
    let id: Int64
    var name: String
    var isPreset: Bool
    var tracksGrams: Bool
    var sortOrder: Int
}

/// One day's intake of one supplement. A row existing means it was taken that day;
/// `grams` is optional (and only meaningful when the supplement tracks grams).
struct SupplementIntake: Equatable {
    let supplementID: Int64
    let day: String      // local calendar day, 'YYYY-MM-DD'
    var grams: Double?
}

/// The single source of truth for a supplement "day key". Kept in one place so the
/// Today card (today's key) and the trends analytics (stepping back day-by-day for
/// streaks) agree exactly. Local calendar, zero-padded 'YYYY-MM-DD' so string order
/// equals chronological order.
enum SupplementDay {
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The key `daysAgo` days before `date` (used to build a trailing window).
    static func key(daysAgo: Int, from date: Date, calendar: Calendar = .current) -> String {
        let shifted = calendar.date(byAdding: .day, value: -daysAgo, to: date) ?? date
        return key(for: shifted, calendar: calendar)
    }

    /// Parse a 'YYYY-MM-DD' key back to a Date (local midnight) for charting.
    static func date(fromKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        return calendar.date(from: components)
    }
}
