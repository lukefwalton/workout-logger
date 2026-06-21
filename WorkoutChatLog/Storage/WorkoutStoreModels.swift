import Foundation

// Value types at the WorkoutStore boundary: the shapes its reads return and its
// writes report back. Each is a fact with database identity, deliberately kept
// distinct from the input drafts in `WorkoutDraft`. Split out of WorkoutStore.swift
// so that file stays focused on SQL and the single write path.

/// Outcome of a successful write. `setIDs` are in submitted order. `achievements`
/// are any personal records detected **inside the same transaction** by comparing
/// the just-saved sets to each exercise's own prior history (§4); it defaults to
/// empty so existing call sites are undisturbed.
struct SaveResult: Equatable {
    let sessionID: Int64
    let setIDs: [Int64]
    let achievements: [Achievement]

    init(sessionID: Int64, setIDs: [Int64], achievements: [Achievement] = []) {
        self.sessionID = sessionID
        self.setIDs = setIDs
        self.achievements = achievements
    }
}

enum WorkoutStoreError: Error, Equatable, CustomStringConvertible {
    /// A second open session was requested while one is already in progress.
    /// The single-open invariant (§1) is maintained in code, not the schema.
    case openSessionExists
    /// A session edit set an end time earlier than its start time.
    case endBeforeStart
    /// Renaming would collide with another exercise's display name — likely a
    /// merge was intended.
    case renameCollision(String)
    /// Merge source and target are the same exercise.
    case selfMerge
    /// A custom exercise can't be deleted while sets still reference it.
    case exerciseInUse(Int)
    /// Seeded exercises aren't deletable (rename or merge instead).
    case cannotDeleteSeeded

    var description: String {
        switch self {
        case .openSessionExists:
            return "A workout is already in progress; finish it before starting another."
        case .endBeforeStart:
            return "A workout can't end before it starts."
        case .renameCollision(let name):
            return "Another exercise is already called \"\(name)\". Merge them instead of renaming."
        case .selfMerge:
            return "Can't merge an exercise into itself."
        case .exerciseInUse(let count):
            return "This exercise is used in \(count) set\(count == 1 ? "" : "s"). Merge it instead of deleting."
        case .cannotDeleteSeeded:
            return "Built-in exercises can't be deleted. Rename or merge instead."
        }
    }
}

/// An exercise as shown in the library-management UI: identity + how heavily it's
/// used + whether it's user-created (so only unused customs can be deleted).
struct ManagedExercise: Equatable, Identifiable {
    let id: Int64
    let canonicalName: String
    let familyKey: String?
    let primaryMuscle: String?
    let isCustom: Bool
    let usageCount: Int
}

/// A set as stored, returned by reads. Deliberately distinct from `SetDraft`
/// (the *input* shape): a draft is a proposal with no identity, a `StoredSet`
/// is a fact with database IDs.
struct StoredSet: Equatable {
    let id: Int64
    let exerciseID: Int64
    let setIndex: Int
    let setType: String
    let weight: Double
    let unit: String
    let loadKind: String
    let reps: Int
    let rir: Int?
    let notes: String?
    let sourceText: String?
}

/// One set from the most recent prior session, for the "last time" hint on the
/// confirm card (§4) — load + reps only, read-only and purely informational.
struct LastTimeSet: Equatable {
    let load: WorkoutLoad
    let reps: Int
}

/// A read-only snapshot of the last time an exercise was logged in a *finished*
/// session (§4). `startedAt` drives the "N days ago" relative label; `sets` are
/// in stored order. Nothing here is written — it only informs the next entry.
struct LastTime: Equatable {
    let startedAt: Date
    let sets: [LastTimeSet]
}

struct WorkoutLoad: Codable, Equatable {
    var kind: WorkoutLoadKind
    var amount: Double?
    var unit: WeightUnit?

    static func stored(kind: WorkoutLoadKind, weight: Double, unit: WeightUnit) -> WorkoutLoad {
        switch kind {
        case .external, .bodyweightPlus, .assisted:
            return WorkoutLoad(kind: kind, amount: weight, unit: unit)
        case .bodyweight:
            return WorkoutLoad(kind: kind, amount: nil, unit: nil)
        case .unspecified:
            return WorkoutLoad(kind: kind, amount: nil, unit: unit)
        }
    }

    /// The canonical (weight, unit) columns to persist for a load kind — the
    /// inverse of `stored(kind:weight:unit:)`. Loadless kinds store NULL so the
    /// nullable schema is meaningful and a bodyweight set never round-trips as
    /// "0 lb"; `loadKind` remains the source of truth either way.
    static func storedColumns(kind: WorkoutLoadKind, weight: Double, unit: WeightUnit) -> (weight: Double?, unit: String?) {
        switch kind {
        case .external, .bodyweightPlus, .assisted:
            return (weight, unit.rawValue)
        case .bodyweight:
            return (nil, nil)
        case .unspecified:
            return (nil, unit.rawValue)
        }
    }

    var displayText: String {
        switch kind {
        case .external:
            return formattedAmountWithUnit ?? "external load"
        case .bodyweight:
            return "BW"
        case .unspecified:
            return "unspecified"
        case .bodyweightPlus:
            guard let formattedAmountWithUnit else { return "BW + load" }
            return "BW + \(formattedAmountWithUnit)"
        case .assisted:
            guard let formattedAmountWithUnit else { return "assisted" }
            return "assisted \(formattedAmountWithUnit)"
        }
    }

    private var formattedAmountWithUnit: String? {
        guard let amount, let unit else { return nil }
        let value = amount.rounded() == amount ? String(Int(amount)) : String(amount)
        return "\(value) \(unit.rawValue)"
    }
}

struct WorkoutSetHistoryRow: Equatable {
    let sessionID: Int64
    let sessionName: String?
    let sessionNotes: String?
    let startedAt: String
    let sessionEndedAt: String?
    let sessionFeel: SessionFeel?
    let sessionIsDeload: Bool
    let setID: Int64
    let exerciseID: Int64
    let exerciseName: String
    let setIndex: Int
    let setType: SetType
    let load: WorkoutLoad
    let reps: Int
    let rir: Int?
    let notes: String?
    let sourceText: String?
    let primaryMuscle: String?      // e.primary_muscle — drives per-muscle analytics (PR 5)
}
