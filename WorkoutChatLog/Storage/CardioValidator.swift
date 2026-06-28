import Foundation

/// Cardio's save guardrail. Unlike `WorkoutValidator` (strength), this never
/// rejects — the whole point of cardio ingestion is that it NEVER fails. Instead
/// it *normalizes*: a blank activity falls back to "Cardio", negative/non-finite
/// metrics are dropped to nil, and zero metrics collapse to nil so a bout with no
/// real numbers stores cleanly rather than as "0 min / 0 mi". The store calls
/// this on the one cardio write path, so the database only ever sees sane rows.
enum CardioValidator {
    static func normalized(_ draft: CardioDraft) -> CardioDraft {
        var out = draft

        let trimmedActivity = draft.activity.trimmingCharacters(in: .whitespacesAndNewlines)
        out.activity = trimmedActivity.isEmpty ? CardioActivity.generic.display : trimmedActivity

        if let d = draft.durationSeconds, d > 0 {
            out.durationSeconds = d
        } else {
            out.durationSeconds = nil
        }

        if let dist = draft.distance, dist.isFinite, dist > 0 {
            out.distance = dist
            out.distanceUnit = draft.distanceUnit ?? .km   // a distance needs a unit
        } else {
            out.distance = nil
            out.distanceUnit = nil
        }

        if let notes = draft.notes?.trimmingCharacters(in: .whitespacesAndNewlines) {
            out.notes = notes.isEmpty ? nil : notes
        }
        return out
    }
}
