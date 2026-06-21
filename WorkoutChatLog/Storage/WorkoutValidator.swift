import Foundation

/// Save guardrails (spec §2.5). The parser is generous about what it accepts;
/// the saver is strict about what it stores, so malformed data never lands
/// silently. The confirm card can still allow deliberate edge cases the model
/// would reject.
enum WorkoutValidator {
    static let minReps = 1
    static let maxReps = 100
    static var repsRange: ClosedRange<Int> { minReps...maxReps }

    static func validate(_ draft: WorkoutDraft) throws {
        guard !draft.sets.isEmpty else { throw ParseError.noSets }
        for set in draft.sets {
            guard !set.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ParseError.emptyExerciseName
            }
            guard set.weight.isFinite, set.weight >= 0 else { throw ParseError.badWeight }  // bodyweight = 0 ok; reject inf/nan
            guard repsRange.contains(set.reps) else { throw ParseError.badReps }
            if let rir = set.rir {
                guard (0...10).contains(rir) else { throw ParseError.badRIR }
            }
        }
    }
}
