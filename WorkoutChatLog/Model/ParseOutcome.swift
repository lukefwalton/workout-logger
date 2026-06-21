import Foundation

/// The result of one parse attempt, shared by every layer of the resolution
/// stack (§1.1). **Foundation only — no `FoundationModels` symbol appears here**,
/// so this type (and everything it touches) compiles and tests on a device, in a
/// simulator, and in the widget process whether or not Apple Intelligence exists.
/// The gated `FoundationWorkoutParser` produces these values; it never sees more
/// than the protocol.
///
/// Doctrine (§1): a parser *proposes* — a draft or a question — and the user
/// confirms before `WorkoutStore` writes. Nothing here can persist anything.
enum ParseOutcome: Equatable {
    /// A confident draft, ready for the confirm card. Still passes through
    /// `WorkoutStore.save` → `WorkoutValidator` like every other draft.
    case draft(WorkoutParseResult)
    /// One short question (FM layer only) — the deterministic path never asks.
    case clarification(ClarificationPrompt)
    /// Not a workout log, or unreadable. The UI says "type it manually."
    /// `reason` is a best-effort diagnosis (rep ranges, cardio, supersets, …)
    /// that lets the status card show *why* the parser stepped back instead of
    /// the generic "try a shape like…" copy. nil = no specific diagnosis.
    case declined(reason: ParseDeclineReason? = nil)
}

/// A specific diagnosis for a declined parse, surfaced in the status card so
/// the user knows what to change instead of guessing. Each case names a real
/// shorthand the parser doesn't yet understand — never a fabricated category.
enum ParseDeclineReason: String, Equatable {
    /// `8-10` style rep ranges. The parser stores a single rep count per set,
    /// not a range, so this declines rather than picking an endpoint silently.
    case repRange
    /// Cardio shorthand like `5k 25min` / `30 min row`. The schema is set/rep
    /// based; cardio belongs in a separate feature, not a guessed weight/reps.
    case cardio
    /// Two or more exercises on one line (`bench 135x8 + curls 30x10`,
    /// `bench 135x8 squat 225x5`). Splitting would invent set/exercise pairings.
    case multiExercise
    /// Weight stated without reps (`bench 135`). Saving a set requires reps.
    case incompleteWeight
    /// `5x5x5`-style ambiguous three-number form where the leading number could
    /// be a set count *or* a weight. The parser declines rather than guess.
    case ambiguousTripleX
}

extension ParseOutcome {
    /// Compatibility shim for the older `case declined` (no associated value).
    /// Most callers don't care about the reason; this keeps them readable.
    static var declined: ParseOutcome { .declined(reason: nil) }
}

/// A parsed draft plus where it came from. `source` drives the "parsed with Apple
/// Intelligence" note on the confirm card; the sets themselves are the flat
/// `SetDraft` every write path already consumes (§2).
struct WorkoutParseResult: Equatable {
    var sets: [SetDraft]
    var source: ParseSource
    /// A short, model-supplied caution about ambiguity (FM only); nil/empty when
    /// the parse was clean. Never a fabricated value — purely advisory text.
    var warning: String?

    init(sets: [SetDraft], source: ParseSource, warning: String? = nil) {
        self.sets = sets
        self.source = source
        self.warning = warning
    }
}

/// Which layer produced a draft. Kept tiny and FM-free; only the UI copy differs.
enum ParseSource: Equatable {
    case deterministic
    case appleIntelligence
}

/// One short clarifying question with up to three tap-to-answer replies. The UI
/// always appends a "Type it manually" escape hatch in addition to these (§"PR 8"),
/// so an empty `suggestedReplies` is still usable.
struct ClarificationPrompt: Equatable {
    let message: String              // intended < 12 words
    let suggestedReplies: [String]   // ≤ 3

    init(message: String, suggestedReplies: [String]) {
        self.message = message
        self.suggestedReplies = suggestedReplies
    }
}

/// The seam between the app and any parser. Async because the FM layer awaits the
/// on-device model; the deterministic layer satisfies it trivially. `context`
/// carries the user's previous clarification replies on a follow-up round and is
/// empty on a first parse.
protocol WorkoutParsing {
    func parse(_ input: String, context: [String]) async -> ParseOutcome
}
