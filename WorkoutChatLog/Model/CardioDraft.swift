import Foundation

// `CardioActivity`, `CardioDistanceUnit`, and `CardioFormat` live in
// Shared/CardioDisplay.swift — they're compiled into the widget target too, so
// the widget renders a bout's activity icon and duration/distance identically
// to the app.

/// One proposed cardio bout, before it is written — the cardio twin of
/// `SetDraft`. The parser proposes; the confirm card lets the user fix anything;
/// only then does `WorkoutStore.saveCardio` write. `durationSeconds` and
/// `distance` are independently optional so "30 min", "5k", and "5k in 25 min"
/// are all representable. `activity` is never empty (the parser guarantees a
/// fallback).
struct CardioDraft: Identifiable, Equatable {
    let id = UUID()
    var activity: String
    var durationSeconds: Int?
    var distance: Double?
    var distanceUnit: CardioDistanceUnit?
    var notes: String?
    var sourceText: String?
    var loggedAt: Date = Date()

    /// Equality ignores `id` and `loggedAt` so parser tests can compare on the
    /// fields that actually carry meaning (mirrors how `SetDraft` fixtures are
    /// compared field-by-field).
    static func == (lhs: CardioDraft, rhs: CardioDraft) -> Bool {
        lhs.activity == rhs.activity
            && lhs.durationSeconds == rhs.durationSeconds
            && lhs.distance == rhs.distance
            && lhs.distanceUnit == rhs.distanceUnit
            && lhs.notes == rhs.notes
            && lhs.sourceText == rhs.sourceText
    }
}

/// A cardio bout as stored, returned by reads — the cardio twin of `StoredSet`.
/// Distinct from `CardioDraft` (a proposal with no identity); this is a fact with
/// a database id.
struct CardioEntry: Identifiable, Equatable {
    let id: Int64
    let activity: String
    let durationSeconds: Int?
    let distance: Double?
    let distanceUnit: CardioDistanceUnit?
    let notes: String?
    let sourceText: String?
    let loggedAt: Date
}
