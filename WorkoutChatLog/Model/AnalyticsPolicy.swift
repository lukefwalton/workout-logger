import Foundation

/// "Hard sets" and "working volume" are *policies*, not facts — some people
/// never log RIR, and what counts as a working set is a judgment call. Making
/// the decision a typed, persistable, eventually-user-facing object keeps those
/// labels from becoming a silent lie buried inside SQL.
///
/// Analytics queries (Track 4, later) read these knobs; they never hardcode the
/// rules. That is what lets the meaning of a chart stay honest as the policy
/// changes.
struct AnalyticsPolicy: Codable, Equatable {
    /// A set at or below this RIR counts as "hard" (close to failure).
    var hardSetRIRThreshold: Int = 4

    /// When RIR is unknown, do we still count the set as hard? Defaults to true:
    /// most people who skip logging RIR were, in fact, training hard.
    var countNullRIRAsHard: Bool = true

    /// Which set types count as a "working" set for volume purposes. Warmups and
    /// backoffs are excluded by default.
    var workingEquivalentSetTypes: Set<SetType> = [.working, .dropset, .myorep, .amrap]

    /// An off day shouldn't read as a regression; a deload week shouldn't either.
    /// These drop flagged sessions from *trend* math only — History still shows
    /// them, nothing is hidden (§ PR 5). Both default on, surfaced as a toggle.
    var excludeOffDays = true
    var excludeDeloadSessions = true

    func countsTowardVolume(_ t: SetType) -> Bool {
        workingEquivalentSetTypes.contains(t)
    }

    /// Whether a session's sets count toward progress trends, given how it felt
    /// and whether it was a deload. Excluded sessions are dropped from charts, not
    /// from History.
    func countsTowardTrend(feel: SessionFeel?, isDeload: Bool) -> Bool {
        if excludeDeloadSessions, isDeload { return false }
        if excludeOffDays, feel == .off { return false }
        return true
    }

    func isHardSet(setType: SetType, rir: Int?) -> Bool {
        guard workingEquivalentSetTypes.contains(setType) else { return false }
        if let rir { return rir <= hardSetRIRThreshold }
        return countNullRIRAsHard
    }

    static let `default` = AnalyticsPolicy()
}
