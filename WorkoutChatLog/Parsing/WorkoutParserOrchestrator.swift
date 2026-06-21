import Foundation

/// Layer 0–1 of the resolution stack as a `WorkoutParsing` adapter: it wraps the
/// deterministic grammar (`DeterministicParser`) and returns `.draft` or
/// `.declined` **only**. The deterministic path never asks a clarification — that
/// is the FM layer's privilege alone (§"PR 8"). `context` is ignored here: the
/// grammar reads syntax, not conversation.
struct DeterministicWorkoutParsing: WorkoutParsing {
    var defaultUnit: WeightUnit = .lb

    func parse(_ input: String, context: [String]) async -> ParseOutcome {
        guard let sets = DeterministicParser.parse(input, defaultUnit: defaultUnit),
              !sets.isEmpty else {
            // On decline, hand a best-effort diagnosis through so the status card
            // can say *why* (rep range, cardio, two exercises on one line, …).
            return .declined(reason: DeterministicParser.diagnoseDecline(input))
        }
        return .draft(WorkoutParseResult(sets: sets, source: .deterministic))
    }
}

/// The resolution orchestrator (§1.1: determinism first, ML last). Runs the
/// deterministic layer; **only** if it declines does the Foundation Models layer
/// — when present — get its one shot. FM is injected as a plain `WorkoutParsing?`,
/// so this type never references a `FoundationModels` symbol and tests can drive
/// it with a fake.
struct WorkoutParserOrchestrator: WorkoutParsing {
    let deterministic: WorkoutParsing
    /// The Layer-4 LLM, or nil when the SDK is absent at compile time or the model
    /// is unavailable at runtime. Wired by `WorkoutParserFactory`.
    let foundation: WorkoutParsing?

    init(deterministic: WorkoutParsing = DeterministicWorkoutParsing(),
         foundation: WorkoutParsing? = nil) {
        self.deterministic = deterministic
        self.foundation = foundation
    }

    func parse(_ input: String, context: [String]) async -> ParseOutcome {
        switch await deterministic.parse(input, context: context) {
        case .draft(let result):
            return .draft(result)
        case .clarification(let prompt):
            // The deterministic layer is contracted never to ask, but pass any
            // future clarification through rather than swallow it.
            return .clarification(prompt)
        case .declined(let reason):
            // Hand off to FM, but preserve the deterministic layer's diagnosis so
            // a final decline (FM also declined / not present) tells the user *why*.
            guard let foundation else { return .declined(reason: reason) }
            let foundationOutcome = await foundation.parse(input, context: context)
            // If FM also declined and had no reason of its own, fall back to the
            // deterministic diagnosis rather than the generic "type it manually".
            if case .declined(let fmReason) = foundationOutcome, fmReason == nil, reason != nil {
                return .declined(reason: reason)
            }
            return foundationOutcome
        }
    }
}

/// Builds the parser the app actually uses. The Foundation Models layer is wired
/// **only** inside `#if canImport(FoundationModels)` *and* only when the on-device
/// model reports itself available at runtime; everywhere else the orchestrator is
/// deterministic-only. The `#else` keeps always-compiled callers (and this file's
/// own signature) free of any FM symbol.
enum WorkoutParserFactory {
    @MainActor
    static func make(store: WorkoutStore,
                     defaultUnit: WeightUnit = UnitPreferences.current()) -> WorkoutParsing {
        WorkoutParserOrchestrator(deterministic: DeterministicWorkoutParsing(defaultUnit: defaultUnit),
                                  foundation: foundationLayer(store: store))
    }

    #if canImport(FoundationModels)
    @MainActor
    static func foundationLayer(store: WorkoutStore) -> WorkoutParsing? {
        // `canImport` only proves the SDK is present; the runtime availability
        // check (Apple Intelligence enabled, model downloaded, eligible device) is
        // what actually decides. Verify the OS floor / symbol names in Xcode.
        guard #available(iOS 26.0, *), FoundationWorkoutParser.isModelAvailable() else {
            return nil
        }
        // Snapshot the user's known lifts once so the model proposes existing
        // canonicals before inventing new ones. A non-isolated read; failures fall
        // back to an empty list rather than blocking parsing.
        let names = (try? store.exerciseNames(limit: 200)) ?? []
        return FoundationWorkoutParser(knownExerciseNames: names)
    }
    #else
    @MainActor
    static func foundationLayer(store: WorkoutStore) -> WorkoutParsing? { nil }
    #endif
}
