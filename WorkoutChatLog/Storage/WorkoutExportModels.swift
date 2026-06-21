import Foundation

// Codable DTOs for the JSON data export/import (Settings → Export / Import). The
// `Exported*` shapes and their snake_case CodingKeys define the on-disk format;
// `ImportSummary` reports what a (possibly dry-run) import did. Split out of
// WorkoutStore.swift; the read/write logic that produces them lives there.

struct WorkoutDataExport: Codable, Equatable {
    let schemaVersion: Int
    let exportedAt: String
    let app: String
    let analyticsPolicy: ExportedAnalyticsPolicy
    let exercises: [ExportedExercise]
    let sessions: [ExportedSession]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case app
        case analyticsPolicy = "analytics_policy"
        case exercises
        case sessions
    }
}

/// What an import did (or would do, for a dry-run preview).
struct ImportSummary: Equatable {
    var addedSessions = 0
    var addedSets = 0
    var addedExercises = 0
    var skippedSessions = 0

    var isEmpty: Bool { addedSessions == 0 && addedExercises == 0 && skippedSessions == 0 }
}

struct ExportedAnalyticsPolicy: Codable, Equatable {
    let hardSetRIRThreshold: Int
    let countNullRIRAsHard: Bool
    let workingEquivalentSetTypes: [String]

    enum CodingKeys: String, CodingKey {
        case hardSetRIRThreshold = "hard_set_rir_threshold"
        case countNullRIRAsHard = "count_null_rir_as_hard"
        case workingEquivalentSetTypes = "working_equivalent_set_types"
    }

    init(_ policy: AnalyticsPolicy) {
        hardSetRIRThreshold = policy.hardSetRIRThreshold
        countNullRIRAsHard = policy.countNullRIRAsHard
        workingEquivalentSetTypes = policy.workingEquivalentSetTypes.map(\.rawValue).sorted()
    }
}

struct ExportedExercise: Codable, Equatable {
    let id: Int64
    let slug: String
    let canonicalName: String
    let familyKey: String?
    let primaryMuscle: String?
    let secondaryMuscles: [String]
    let isCustom: Bool
    let aliases: [String]
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case slug
        case canonicalName = "canonical_name"
        case familyKey = "family_key"
        case primaryMuscle = "primary_muscle"
        case secondaryMuscles = "secondary_muscles"
        case isCustom = "is_custom"
        case aliases
        case createdAt = "created_at"
    }
}

struct ExportedSession: Codable, Equatable {
    let id: Int64
    let startedAt: String
    let endedAt: String?
    let name: String?
    let notes: String?
    let feel: String?
    let isDeload: Bool
    let createdAt: String
    var sets: [ExportedSet]

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case name
        case notes
        case feel
        case isDeload = "is_deload"
        case createdAt = "created_at"
        case sets
    }
}

struct ExportedSet: Codable, Equatable {
    let id: Int64
    let exerciseID: Int64
    let exerciseName: String
    let setIndex: Int
    let setType: String
    let load: WorkoutLoad
    let reps: Int
    let rir: Int?
    let notes: String?
    let sourceText: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case exerciseID = "exercise_id"
        case exerciseName = "exercise_name"
        case setIndex = "set_index"
        case setType = "set_type"
        case load
        case reps
        case rir
        case notes
        case sourceText = "source_text"
        case createdAt = "created_at"
    }
}
