import Foundation

/// The knobs behind the calorie estimate, typed like `AnalyticsPolicy` so the
/// numbers are never magic constants buried in code. The estimate is deliberately
/// rough and honestly framed (§ PR 11) — these make "rough" explicit and tunable.
struct CaloriePolicy: Equatable {
    /// Metabolic equivalent for resistance training (~5.0). `kcal ≈ MET × kg × hours`.
    var met: Double = 5.0
    /// Cap absurd durations (e.g. a session left open for hours between sets).
    var maxSessionHours: Double = 6.0
    /// A single-set session (zero set-span) still took *some* time; use a small fixed
    /// duration rather than 0 or a fabricated longer one.
    var singleSetFallbackMinutes: Double = 10.0

    static let `default` = CaloriePolicy()
}

/// Keys shared with PR 10's `HealthPreferences.manualBodyweightKgKey` (same string),
/// so the manual bodyweight is a single value whether it's entered in the Apple Health
/// section (PR 10) or the Calorie-estimate section here. When both land, dedupe the
/// duplicate Settings row — the data already agrees.
enum CaloriePreferences {
    static let bodyweightKgKey = "settings.health.manualBodyweightKg"
}

/// A deterministic, clearly-rough per-session kcal estimate. **AI never touches this**;
/// it's pure arithmetic over real session timestamps and a known bodyweight, and it
/// refuses to invent — missing inputs yield a prompt, never a fake number.
enum CalorieEstimate {
    /// Which input the duration came from (drives nothing user-facing beyond honesty
    /// in tests/diagnostics; precedence order is the spec's).
    enum DurationSource: Equatable { case explicitBounds, setSpan, manual }

    struct Duration: Equatable {
        let hours: Double
        let source: DurationSource
    }

    enum Outcome: Equatable {
        case kcal(Int, DurationSource)   // rounded; rough by design
        case needsBodyweight             // duration known, bodyweight missing
        case needsDuration               // no usable duration at all
    }

    /// Duration by precedence: explicit `ended − started` → set-span → manual → none.
    /// Degenerate cases are clamped, never invented. `startedAt` is optional: a
    /// malformed/unparseable start simply disqualifies the explicit-bounds tier (the
    /// set-span tier doesn't need it) rather than being faked into a wrong duration.
    static func resolveDuration(startedAt: Date?,
                                endedAt: Date?,
                                setSpanSeconds: Double?,
                                manualSeconds: Double?,
                                policy: CaloriePolicy = .default) -> Duration? {
        let capSeconds = policy.maxSessionHours * 3600

        if let startedAt, let endedAt {
            let seconds = endedAt.timeIntervalSince(startedAt)
            if seconds > 0 { return Duration(hours: min(seconds, capSeconds) / 3600, source: .explicitBounds) }
        }
        if let setSpanSeconds {
            // A real (possibly single-set) workout happened. A zero span = one set →
            // small fixed fallback; a huge span (left open) is capped.
            let seconds = setSpanSeconds > 0 ? setSpanSeconds : policy.singleSetFallbackMinutes * 60
            return Duration(hours: min(seconds, capSeconds) / 3600, source: .setSpan)
        }
        if let manualSeconds, manualSeconds > 0 {
            return Duration(hours: min(manualSeconds, capSeconds) / 3600, source: .manual)
        }
        return nil
    }

    static func kcal(bodyweightKg: Double, durationHours: Double, met: Double) -> Double {
        met * bodyweightKg * durationHours
    }

    /// Full resolution → an outcome the UI renders directly. Duration is checked
    /// first (most sessions have a set-span); then bodyweight.
    static func estimate(startedAt: Date?,
                         endedAt: Date?,
                         setSpanSeconds: Double?,
                         manualSeconds: Double?,
                         bodyweightKg: Double?,
                         policy: CaloriePolicy = .default) -> Outcome {
        guard let duration = resolveDuration(startedAt: startedAt, endedAt: endedAt,
                                             setSpanSeconds: setSpanSeconds, manualSeconds: manualSeconds,
                                             policy: policy) else {
            return .needsDuration
        }
        guard let bodyweightKg, bodyweightKg > 0, bodyweightKg.isFinite else { return .needsBodyweight }
        let value = kcal(bodyweightKg: bodyweightKg, durationHours: duration.hours, met: policy.met)
        return .kcal(Int(value.rounded()), duration.source)
    }
}
