import Foundation
@testable import WorkoutChatLog

/// A scripted `WorkoutParsing` for the PR 8 tests. It **never imports
/// FoundationModels** — the whole point of the protocol seam is that the app's
/// behavior around the LLM is driven by a fake here, while the real FM parser is
/// verified separately on-device. Returns one scripted outcome per `parse` call
/// and records the `(input, context)` it was asked, so a test can assert that a
/// reply re-invokes parsing with the original text plus the chosen reply.
final class FakeWorkoutParsing: WorkoutParsing {
    var scriptedOutcomes: [ParseOutcome]
    private(set) var calls: [(input: String, context: [String])] = []

    init(_ outcomes: [ParseOutcome]) { self.scriptedOutcomes = outcomes }
    convenience init(_ outcome: ParseOutcome) { self.init([outcome]) }

    var callCount: Int { calls.count }

    func parse(_ input: String, context: [String]) async -> ParseOutcome {
        calls.append((input, context))
        let index = calls.count - 1
        if index < scriptedOutcomes.count { return scriptedOutcomes[index] }
        return scriptedOutcomes.last ?? .declined
    }
}

/// A parser whose `parse` calls suspend until the test resumes them, so two
/// in-flight parses can be completed **out of order** — exactly the race the
/// latest-request guard in `TodayModel.runParse` defends against. An `actor` so its
/// continuation bookkeeping is Sendable-safe across the overlapping tasks.
actor GatedFakeParser: WorkoutParsing {
    private var continuations: [CheckedContinuation<ParseOutcome, Never>] = []
    private(set) var startedCount = 0

    func parse(_ input: String, context: [String]) async -> ParseOutcome {
        startedCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    /// Resume the Nth started parse (0-based) with a chosen outcome.
    func resume(at index: Int, with outcome: ParseOutcome) {
        continuations[index].resume(returning: outcome)
    }
}

extension ParseOutcome {
    /// A small draft fixture for tests that don't care about the exact sets.
    static func draftFixture(exercise: String = "Dumbbell Bench Press",
                             weight: Double = 40,
                             reps: Int = 8,
                             source: ParseSource = .appleIntelligence) -> ParseOutcome {
        .draft(WorkoutParseResult(
            sets: [SetDraft(exerciseName: exercise, weight: weight, unit: .lb,
                            loadKind: .external, reps: reps, rir: nil,
                            setType: .working, notes: nil, sourceText: "fixture")],
            source: source))
    }
}
