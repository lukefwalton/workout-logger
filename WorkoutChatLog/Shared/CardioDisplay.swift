import Foundation

// Cardio display primitives shared between the app and the widget (this file is
// compiled into both targets, like SharedDatabase/WorkoutDateFormat). They moved
// here from Model/CardioDraft.swift so the widget can render a cardio bout's
// activity icon and duration/distance *identically* to History and the confirm
// card without linking any app-only Model types. Everything here is
// Foundation-only by design.

/// The distance unit a cardio entry was logged in. Stored verbatim like
/// `WeightUnit` — the app never silently converts, so an exported/redisplayed
/// cardio entry reads back exactly as it was logged. `m` (meters) covers pool
/// swims and erg distances; `mi`/`km` cover road work.
enum CardioDistanceUnit: String, Codable, CaseIterable {
    case mi, km, m

    var label: String {
        switch self {
        case .mi: "mi"
        case .km: "km"
        case .m: "m"
        }
    }
}

/// Shared presentation helpers for a cardio bout — used by the confirm card, the
/// history row, and the widget so all render duration/distance identically.
enum CardioFormat {
    /// "30 min", "1h 05m", "45s", or nil when there's no duration.
    static func duration(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return m > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(h)h" }
        if m > 0 { return s > 0 ? "\(m)m \(String(format: "%02d", s))s" : "\(m) min" }
        return "\(s)s"
    }

    /// "5 km", "3.1 mi", "1000 m", or nil when there's no distance.
    static func distance(_ value: Double?, unit: CardioDistanceUnit?) -> String? {
        guard let value, value > 0, let unit else { return nil }
        let number = value.rounded() == value ? String(Int(value)) : String(value)
        return "\(number) \(unit.label)"
    }

    /// One-line summary like "30 min · 5 km", "5 km", or "logged" when neither is
    /// present — never empty, so a metric-less bout still reads as something.
    static func summary(durationSeconds: Int?, distance value: Double?, distanceUnit: CardioDistanceUnit?) -> String {
        let parts = [duration(durationSeconds), distance(value, unit: distanceUnit)].compactMap { $0 }
        return parts.isEmpty ? "logged" : parts.joined(separator: " · ")
    }
}

/// A canonical cardio activity. The whole point of cardio ingestion is that it
/// NEVER fails: any phrasing the user types resolves to the closest activity
/// here, and anything we genuinely can't place keeps the user's own words (or
/// falls back to a plain "Cardio"). No input is ever rejected.
///
/// `keywords` are matched as whole words (so "swim" never matches "swimmers"),
/// and include common inflections so "ran"/"running" both land on Run.
enum CardioActivity: CaseIterable {
    case run, cycle, row, swim, walk, hike, elliptical, stairs, jumpRope, ski, generic

    var display: String {
        switch self {
        case .run: "Run"
        case .cycle: "Cycling"
        case .row: "Rowing"
        case .swim: "Swimming"
        case .walk: "Walk"
        case .hike: "Hike"
        case .elliptical: "Elliptical"
        case .stairs: "Stair Climber"
        case .jumpRope: "Jump Rope"
        case .ski: "Ski Erg"
        case .generic: "Cardio"
        }
    }

    /// SF Symbol for the confirm card / history row / widget. Never emoji (house style).
    var icon: String {
        switch self {
        case .run: "figure.run"
        case .cycle: "figure.outdoor.cycle"
        case .row: "figure.rower"
        case .swim: "figure.pool.swim"
        case .walk: "figure.walk"
        case .hike: "figure.hiking"
        case .elliptical: "figure.elliptical"
        case .stairs: "figure.stair.stepper"
        case .jumpRope: "figure.jumprope"
        case .ski: "figure.skiing.crosscountry"
        case .generic: "heart.circle.fill"
        }
    }

    /// Whole-word keywords (and short multi-word phrases) that resolve to this
    /// activity. Order within `CardioActivity.allCases` is the match priority.
    var keywords: [String] {
        switch self {
        case .run: ["run", "ran", "running", "jog", "jogged", "jogging", "sprint", "sprints", "treadmill"]
        case .cycle: ["bike", "biked", "biking", "cycle", "cycled", "cycling", "spin", "spinning", "peloton", "ride", "rode", "stationary bike"]
        case .row: ["row", "rowed", "rowing", "rower", "erg", "concept2"]
        case .swim: ["swim", "swam", "swimming", "swum", "laps"]
        case .walk: ["walk", "walked", "walking", "steps", "rucking", "ruck"]
        case .hike: ["hike", "hiked", "hiking", "trek", "trekking"]
        case .elliptical: ["elliptical", "cross trainer"]
        case .stairs: ["stairmaster", "stairmill", "stepmill", "stair climber", "stair stepper", "stairs"]
        case .jumpRope: ["jump rope", "jumprope", "skipping", "skip rope", "double unders"]
        case .ski: ["ski erg", "skierg", "ski"]
        case .generic: ["cardio", "conditioning", "hiit"]
        }
    }
}

/// SF Symbol for a *stored* activity string. Stored activities are the canonical
/// `CardioActivity` display names whenever the parser matched a keyword ("Run",
/// "Cycling", …), so the icon derives from the enum by display name — no
/// duplicated map to drift. Genuinely free-text activities honestly fall back
/// to the generic heart; keyword/fuzzy matching stays in the parser.
enum CardioActivityIcon {
    static func symbol(forActivity activity: String) -> String {
        CardioActivity.allCases.first {
            $0.display.caseInsensitiveCompare(activity) == .orderedSame
        }?.icon ?? CardioActivity.generic.icon
    }
}
