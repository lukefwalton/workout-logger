#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Layer 4 of the resolution stack (§1.1): the on-device LLM, reached **only**
/// when every deterministic layer has declined. The entire file is wrapped in
/// `#if canImport(FoundationModels)` so not one FM symbol — `SystemLanguageModel`,
/// `LanguageModelSession`, `@Generable`, `@Guide` — can leak into always-compiled
/// code. It conforms to the common `WorkoutParsing` protocol; the orchestrator and
/// `TodayModel` only ever see that protocol.
///
/// No write power (§1): it returns a **draft** or a **question** (or declines). The
/// user confirms; `WorkoutStore` writes. The mapping back to canonical types is
/// done by the FM-free, unit-tested `ModelDraftMapping`.
///
/// NOT COMPILED HERE (Linux, no FoundationModels SDK). The symbol names and the
/// `iOS 26.0` floor below are from the spec and must be verified against the
/// installed SDK in Xcode — the SDK is the source of truth, not the spec.
@available(iOS 26.0, *)
struct FoundationWorkoutParser: WorkoutParsing {
    /// A snapshot of the user's known canonical names (captured as a value, not the
    /// store) so this type stays free of write-path coupling. Fed to the model so
    /// it proposes existing lifts before inventing new ones.
    let knownExerciseNames: [String]

    /// The compile gate proves the SDK exists; this proves the on-device model is
    /// actually usable right now (eligible device, Apple Intelligence enabled,
    /// model downloaded). Anything other than `.available` → treat as no FM.
    static func isModelAvailable() -> Bool {
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        default:
            // `.unavailable(_)` and any future case → unavailable. A coarse switch
            // on purpose: we never want a new reason to read as "available."
            return false
        }
    }

    func parse(_ input: String, context: [String]) async -> ParseOutcome {
        guard Self.isModelAvailable() else { return .declined }

        let session = LanguageModelSession(instructions: Self.instructions(knownExerciseNames: knownExerciseNames))
        do {
            let response = try await session.respond(to: Self.prompt(input: input, context: context),
                                                     generating: ModelParseResponse.self)
            return Self.outcome(from: response.content, sourceText: input)
        } catch {
            // A model error (timeout, guardrail refusal, decode failure) is a
            // decline to the user — never a crash, never a fabricated draft. But
            // surface it in DEBUG so an SDK/integration regression (wrong symbol,
            // decode mismatch, unexpected availability) isn't indistinguishable
            // from the user simply typing non-workout prose. Log the error only —
            // never the user's input — so nothing identifiable is recorded.
            #if DEBUG
            print("[FoundationWorkoutParser] model parse failed, declining: \(error)")
            #endif
            return .declined
        }
    }

    // MARK: - Prompt

    /// The rules live in `instructions` (with the known-lift list); the user's text
    /// (plus any clarification replies) goes in `prompt`. Keeping the two separate
    /// is the documented FM pattern and keeps the user text from rewriting the rules.
    static func instructions(knownExerciseNames: [String]) -> String {
        let known = knownExerciseNames.isEmpty
            ? "(the user has no saved exercises yet)"
            : knownExerciseNames.joined(separator: ", ")
        return """
        You convert a single line of weightlifting shorthand into structured data. \
        You never write anything; you only propose a draft the user confirms and can \
        edit. Be generous: people type sets however they like, and the confirm card \
        lets them fix anything you get wrong. Lean toward a usable draft over a refusal.

        Decide one kind:
        - "draft": it reads as a logged set. Make your best effort even if the exercise \
        is unfamiliar or a field is ambiguous — the user corrects it on the card.
        - "clarification": only when a single missing field blocks a usable draft and \
        you truly can't guess it. Ask a question under 12 words with up to 3 short \
        suggested replies.
        - "declined": reserve for text that is clearly not a workout at all (chit-chat, \
        notes with no set). Do NOT decline just because the exercise is unknown.

        Give an exerciseName whenever the line names or clearly implies a lift: the \
        closest known exercise when one matches, otherwise a clean title-cased name for a \
        new custom lift (set isNewExercise true). Never refuse just because a lift isn't in \
        the known list. But if the line is a pure scheme with no exercise at all (e.g. \
        "5x3", "8x3x4"), leave exerciseName empty — the user names it on the confirm card. \
        Never invent a lift the user didn't mention.

        Ambiguous "A x B" with no weight (e.g. "5x3") is sets × reps: read the first \
        number as the set count, the second as reps, and put a short note in `warning` \
        like "Read as 5 sets × 3 reps — swap on the card if that's backwards." For "A x B \
        x C" read A sets × B reps and warn similarly. A confident weight (has a unit or is \
        clearly heavier than a set count) is the load, not a set count.

        Never invent reps, RIR, or a specific load you didn't see — leave load 0 / \
        unspecified and reps to your honest best read. Prefer these known exercises when \
        one clearly matches: \(known).

        loadKind is one of: external, bodyweight, unspecified, bodyweightPlus, assisted. \
        setType is one of: working, warmup, dropset, myorep, amrap, backoff. unit is "lb", \
        "kg", or null. reps is 1–100. rir is 0–10 or null.
        """
    }

    static func prompt(input: String, context: [String]) -> String {
        guard !context.isEmpty else { return input }
        // The original line is preserved; the user's clarification replies are
        // appended as additional context, never replacing it.
        let replies = context.joined(separator: "; ")
        return """
        Original entry: \(input)
        The user clarified: \(replies)
        Re-parse the original entry using that clarification.
        """
    }

    // MARK: - Mapping (delegates the defensive logic to FM-free ModelDraftMapping)

    static func outcome(from response: ModelParseResponse, sourceText: String) -> ParseOutcome {
        switch response.kind.lowercased() {
        case "draft":
            guard let workout = response.workout else { return .declined }
            let mapped = workout.sets.map { set in
                ModelDraftMapping.setDraft(amount: set.amount,
                                           unit: set.unit,
                                           loadKind: set.loadKind,
                                           reps: set.reps,
                                           rir: set.rir,
                                           setType: set.setType,
                                           exerciseName: workout.exerciseName,
                                           sourceText: sourceText)
            }
            guard let result = ModelDraftMapping.result(mappedSets: mapped,
                                                        source: .appleIntelligence,
                                                        warning: response.warning) else {
                return .declined
            }
            return .draft(result)
        case "clarification":
            guard let prompt = ModelDraftMapping.clarification(message: response.clarificationQuestion ?? "",
                                                               replies: response.suggestedReplies) else {
                return .declined
            }
            return .clarification(prompt)
        default:
            return .declined
        }
    }
}

// MARK: - @Generable response shape (spec §"PR 8")

@available(iOS 26.0, *)
@Generable
struct ModelParseResponse {
    @Guide(description: "draft, clarification, or declined") var kind: String
    @Guide(description: "Parsed workout draft if kind is draft.") var workout: ModelWorkoutParse?
    @Guide(description: "Short clarification question (< 12 words) if kind is clarification.") var clarificationQuestion: String?
    @Guide(description: "Up to 3 suggested reply buttons for a clarification.") var suggestedReplies: [String]
    @Guide(description: "Short warning if the input was ambiguous; else empty.") var warning: String
}

@available(iOS 26.0, *)
@Generable
struct ModelWorkoutParse {
    // Title-cased here so a *first-sighting* lift lands with a tidy display name. The
    // store's `WorkoutStore.normalizeName` preserves that casing on insert; subsequent
    // logs that come back in a different case still fold onto the same row via
    // `COLLATE NOCASE`. So this is the casing the user *sees* the first time a lift
    // shows up, not a matching key.
    @Guide(description: "Canonical exercise name, title-cased if possible.") var exerciseName: String
    @Guide(description: "One or more parsed sets.") var sets: [ModelSetParse]
    @Guide(description: "True if this looks like an exercise not in the known list.") var isNewExercise: Bool
}

@available(iOS 26.0, *)
@Generable
struct ModelSetParse {
    @Guide(description: "Weight amount; 0 if bodyweight/unspecified.") var amount: Double?
    @Guide(description: "lb or kg; null if not stated.") var unit: String?
    @Guide(description: "external, bodyweight, unspecified, bodyweightPlus, or assisted.") var loadKind: String
    @Guide(description: "Reps, 1–100.") var reps: Int
    @Guide(description: "Reps in reserve, 0–10; null if not stated.") var rir: Int?
    @Guide(description: "working, warmup, dropset, myorep, amrap, or backoff.") var setType: String
}
#endif
