import Foundation

/// State + logic behind the Today tab's first real flow: type a set in shorthand
/// → parse → confirm → save. Kept separate from the SwiftUI view so the
/// behavior (parse, decline, name-edit, save outcomes) is unit-testable without
/// a running UI. The view is thin glue over this.
///
/// Embodies the doctrine: the parser *proposes* a draft, the user *confirms*
/// (and can name a bare scheme), and only then does `WorkoutStore` *write*.
///
/// `@MainActor` because it owns published UI state and calls the main-actor
/// mutating store APIs (`save`); the store's reads stay non-isolated.
@MainActor
final class TodayModel: ObservableObject {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case freeForm
        case workoutPlan

        var id: String { rawValue }

        var title: String {
            switch self {
            case .freeForm: "Free Form"
            case .workoutPlan: "Workout Plan"
            }
        }
    }

    enum Status: Equatable {
        case idle
        case declined           // neither the grammar nor the LLM could read it
        case needsClarification(ClarificationPrompt)   // FM asked one short question (PR 8)
        case saved(Int)         // n sets written
        case savedCardio(String) // a cardio bout written (summary line)
        case failed(String)
    }

    struct PlannedExercise: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var loggedSetCount: Int = 0
    }

    struct SavedPlan: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var text: String
    }

    @Published var inputText = "" {
        didSet { refreshInputAutocomplete() }
    }
    /// Live exercise-name suggestions for the current `inputText`, computed
    /// against the canonical/alias library. Empty until the user has typed at
    /// least two letters of a recognizable lift prefix; capped tight so the
    /// chips never push the input off-screen. Tapping one rewrites the leading
    /// name span; the rest of the line (`135x8`) is preserved.
    @Published private(set) var inputSuggestions: [ExerciseSuggestion] = []
    @Published var mode: Mode = .freeForm {
        didSet { persistActivePlan() }
    }
    @Published var planName = "" {
        didSet { persistActivePlan() }
    }
    @Published var planText = "" {
        didSet { persistActivePlan() }
    }
    @Published private(set) var savedPlans: [SavedPlan] = []
    @Published private(set) var selectedSavedPlanID: UUID?
    @Published private(set) var plannedExercises: [PlannedExercise] = []
    @Published private(set) var selectedPlannedExerciseID: UUID?
    @Published private(set) var pending: WorkoutDraft?
    /// A pending cardio bout awaiting confirmation. Mutually exclusive with
    /// `pending` (a line is either strength or cardio), so the confirm UI shows
    /// at most one card. Cardio is stored on its own write path (`saveCardio`),
    /// independent of the strength session.
    @Published private(set) var pendingCardio: CardioDraft?
    /// Later segments of a multi-entry line ("bench 135x8 + curl 30x10", a
    /// pasted multi-line log), waiting their turn. The confirm card holds
    /// exactly one exercise, so the entries take turns: confirming (or logging
    /// cardio for) the current one pops the next segment into the input box.
    /// Cleared by discard / type-it-manually / plan switches — bailing on the
    /// current entry bails on the rest of the breath too.
    @Published private(set) var queuedEntries: [String] = []
    @Published private(set) var pendingCreatesNewExercise = false
    /// Layer-2 fuzzy candidates shown above the new-exercise notice when a save
    /// would create a new lift — "Did you mean …?". Tapping one renames; nothing
    /// auto-applies (§1.1).
    @Published private(set) var pendingSuggestions: [ExerciseSuggestion] = []
    /// The "last time" hint for the pending exercise (§4) — the most recent
    /// finished session's sets for it, shown read-only on the confirm card. nil
    /// when the name is unresolved or the lift has no prior finished session.
    /// Tracks `pending` exactly: populated when a name resolves, cleared with it.
    @Published private(set) var lastTime: LastTime?
    /// Which layer produced the pending draft, so the confirm card can show the
    /// "parsed with Apple Intelligence" note for FM drafts only (PR 8).
    @Published private(set) var pendingParseSource: ParseSource?
    /// True while an async parse (deterministic or FM) is in flight, so the view can
    /// disable the controls that would start a second, overlapping parse.
    @Published private(set) var isParsing = false
    @Published private(set) var status: Status = .idle

    /// Why the most recent parse was declined (rep range, cardio, supersets, …),
    /// surfaced under the generic "couldn't read that one yet" copy so the user
    /// learns what to change instead of guessing. nil = no specific diagnosis.
    @Published private(set) var lastDeclineReason: ParseDeclineReason?

    /// Personal records detected on the most recent save (§4), surfaced as a
    /// tasteful notice under "Saved N sets" and cleared when a new entry begins.
    /// A *notice*, not stored analytics — recomputed from logged sets each save.
    @Published private(set) var lastAchievements: [Achievement] = []

    /// The most recent save's set IDs + session id, kept transiently so the user
    /// can tap "Undo" right after a save and have those sets deleted (and the
    /// session retired when its set count drops to zero). Cleared by any other
    /// flow (a new parse, a discard, the next save) so undo always refers to
    /// the visible "saved N sets" notice.
    @Published private(set) var lastSaveUndoToken: UndoToken?

    struct UndoToken: Equatable {
        let sessionID: Int64
        let setIDs: [Int64]
    }

    /// The open session confirmed sets append to, and its running set count, for
    /// the active-workout banner. nil = no workout in progress.
    @Published private(set) var activeSessionID: Int64?
    @Published private(set) var activeSessionSetCount = 0

    var hasActiveWorkout: Bool { activeSessionID != nil }

    private let store: WorkoutStore
    private var parser: WorkoutParsing
    /// Whether the parser was injected (tests) — tests pin the parser to a fake
    /// regardless of unit preference, so we never overwrite it on a Settings flip.
    private let parserWasInjected: Bool
    private let planStore: PlanStore
    /// Opt-in Apple Health bridge (PR 10). Holds a `HealthService` so this model
    /// stays HealthKit-symbol-free; it no-ops unless the user enabled the toggle and
    /// granted permission.
    private let health: HealthWorkoutCoordinator
    /// Best-effort post-finish side effects: HealthKit write + widget reload.
    private let workoutFinish: WorkoutFinishCoordinator
    /// Decides whether an open session should be adopted or auto-finished.
    private let sessionReconciler = SessionReconciler()
    private var isRestoringPlanState = false
    private var pendingPlannedExerciseID: UUID?

    /// Handle to the most recent best-effort Health write (PR 10), exposed so tests can
    /// await the fire-and-forget write deterministically. Production never reads it.
    private(set) var pendingHealthWrite: Task<Void, Never>?

    /// Clarification follow-up state (PR 8). The original entry is preserved so each
    /// reply re-parses it with the accumulated replies as context; the round counter
    /// enforces the cap so the LLM can't loop forever.
    private var clarificationInput: String?
    private var clarificationReplies: [String] = []
    private var clarificationRounds = 0

    /// Monotonic token for the async parse lifecycle. Parsing is now `async` (the FM
    /// path awaits the on-device model), so a fast second submit — or repeated
    /// clarification-reply taps — can have an older, slower call resolve *after* a
    /// newer one. Each `runParse` claims the next token and, on resume, applies its
    /// result only if it is still the latest; stale results are dropped. Mutated and
    /// read on the main actor (this class is `@MainActor`), so the check is race-free.
    private var parseGeneration = 0

    /// After this many clarification questions without a draft, decline and tell the
    /// user to type it manually (spec §"PR 8": "Round cap = 2").
    static let maxClarificationRounds = 2

    init(store: WorkoutStore,
         parser: WorkoutParsing? = nil,
         planDefaults: UserDefaults = .standard,
         health: HealthWorkoutCoordinator = HealthWorkoutCoordinator(),
         embedding: ExerciseEmbedding = ExerciseEmbeddingFactory.make()) {
        self.store = store
        // Default to the real orchestrator (deterministic → FM when available);
        // tests inject a fake `WorkoutParsing` so they never import FoundationModels.
        self.parser = parser ?? WorkoutParserFactory.make(store: store)
        self.parserWasInjected = parser != nil
        self.planStore = PlanStore(defaults: planDefaults)
        self.health = health
        self.workoutFinish = WorkoutFinishCoordinator(health: health)
        // Layer 3 (semantic) is opportunistic: a `NoopEmbedding` unless real on-device
        // embeddings load, so resolution falls back to fuzzy/FM with no behavior change.
        self.semanticSuggester = SemanticSuggester(embedding: embedding,
                                                   threshold: WorkoutStore.semanticEscalationThreshold)
        restorePlans()
    }

    /// Layer 3 of the resolution stack (§1.1): semantic suggestions, consulted only
    /// when fuzzy is low-confidence. Holds the embedding behind the `ExerciseEmbedding`
    /// protocol so this model carries no `NaturalLanguage` symbol.
    private let semanticSuggester: SemanticSuggester
    /// Canonical-name vectors, embedded once and cached in memory (re-embedding the
    /// registry on every keystroke would be wasteful). nil until first built; rebuilt
    /// lazily. Empty when embeddings aren't ready.
    private var semanticCandidateCache: [SemanticSuggester.Candidate]?

    /// The exercise name shared by the pending draft's sets (one entry = one
    /// exercise). Empty for a bare scheme like "3x10" until the user names it.
    var pendingExerciseName: String {
        pending?.sets.first?.exerciseName ?? ""
    }

    var canSave: Bool {
        guard let pending else { return false }
        guard !pendingExerciseName.trimmingCharacters(in: .whitespaces).isEmpty,
              !pending.sets.isEmpty else { return false }
        // Reps are now editable on the confirm card (a recovered name-only draft
        // starts with reps unset = 0), so gate Save on every set having a valid
        // rep count instead of letting the save fail validation after the fact.
        return pending.sets.allSatisfy { WorkoutValidator.repsRange.contains($0.reps) }
    }

    var selectedPlannedExercise: PlannedExercise? {
        guard let selectedPlannedExerciseID else { return nil }
        return plannedExercises.first { $0.id == selectedPlannedExerciseID }
    }

    var canStartPlan: Bool {
        !Self.parsePlanText(planText).isEmpty
    }

    /// Parse the current input through the resolution stack (deterministic → FM).
    /// `async` because the FM layer awaits the on-device model; the deterministic
    /// path resolves immediately. A fresh parse always clears any in-flight
    /// clarification — it's a new entry, not a reply.
    func parse() async {
        clearClarificationState()
        await runParse(input: inputText, context: [])
    }

    /// Rebuild the parser when the user changes their preferred unit in
    /// Settings. The store reference is unchanged; only the deterministic layer's
    /// `defaultUnit` differs. A test-injected parser is left alone — tests pin
    /// the parser to a fake regardless of unit, by design.
    ///
    /// **Pending-draft handling.** The current `SetDraft` doesn't track whether
    /// a unit was explicitly typed (`60kg`) or default-applied to an ambiguous
    /// `100x5`, so we can't safely retag a confirmed `.external` set. The
    /// pessimistic-but-honest fix: only retag `.unspecified` sets (a bare
    /// scheme that's waiting for the user to confirm a load). For `.external`
    /// draft sets the user has the confirm-card unit toggle as the escape
    /// valve — flipping that *is* the explicit per-entry override.
    func setDefaultUnit(_ unit: WeightUnit) {
        guard !parserWasInjected else { return }
        parser = WorkoutParserFactory.make(store: store, defaultUnit: unit)
        guard var draft = pending else { return }
        for index in draft.sets.indices where draft.sets[index].loadKind == .unspecified {
            draft.sets[index].unit = unit
        }
        pending = draft
    }

    /// Answer the current clarification with a model-suggested reply. Re-parses the
    /// **original** entry with the accumulated replies as context (PR 8). Does
    /// nothing if there's no clarification in flight.
    func replyToClarification(_ reply: String) async {
        guard let input = clarificationInput else { return }
        clarificationReplies.append(reply)
        await runParse(input: input, context: clarificationReplies)
    }

    /// The always-present escape hatch under a clarification: drop the question and
    /// return to plain input (the typed text is kept so the user can edit it).
    /// Invalidates any in-flight reply parse so a slow result can't land afterward
    /// and resurrect the clarification the user just dismissed.
    func typeItManually() {
        invalidateInFlightParse()
        clearClarificationState()
        pending = nil
        pendingCardio = nil
        queuedEntries = []
        clearPendingResolutionHints()
        pendingParseSource = nil
        status = .idle
    }

    private func runParse(input: String, context: [String]) async {
        parseGeneration += 1
        let generation = parseGeneration
        isParsing = true
        let started = ContinuousClock.now
        lastAchievements = []   // a new entry supersedes any prior save's PR notice
        lastSaveUndoToken = nil // …and so does the undo notice for the prior save
        let outcome = await parser.parse(input, context: context)
        // A newer parse/reply — or an explicit exit (typeItManually/discard) — bumped
        // the token while this one was awaiting. Drop this stale result so it can't
        // overwrite fresher state or resurrect a dismissed clarification/draft.
        guard generation == parseGeneration else { return }
        let minimumSpinner: Duration = .milliseconds(500)
        let elapsed = started.duration(to: ContinuousClock.now)
        if elapsed < minimumSpinner {
            try? await Task.sleep(for: minimumSpinner - elapsed)
            guard generation == parseGeneration else { return }
        }
        isParsing = false
        apply(outcome, input: input)
    }

    /// Bump the parse token so any in-flight async parse is treated as stale on
    /// resume, and clear the in-flight flag. Used when the user explicitly leaves a
    /// parse-driven flow (type-it-manually / discard).
    private func invalidateInFlightParse() {
        parseGeneration += 1
        isParsing = false
    }

    private func apply(_ outcome: ParseOutcome, input: String) {
        // A fresh outcome supersedes any pending cardio bout; the cardio branch
        // below re-sets it when this line is cardio.
        pendingCardio = nil
        switch outcome {
        case .draft(let result):
            let planned = applySelectedPlannedExerciseIfNeeded(to: result.sets)
            pending = WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: applyBodyweightDefault(to: planned.sets))
            pendingPlannedExerciseID = planned.loggedRowID
            pendingParseSource = result.source
            refreshPendingExerciseResolution()
            clearClarificationState()
            lastDeclineReason = nil
            status = .idle

        case .clarification(let prompt):
            // First clarification of this entry preserves the original text for
            // follow-ups; subsequent ones keep it. The counter caps the loop.
            if clarificationInput == nil { clarificationInput = input }
            clarificationRounds += 1
            pending = nil
            clearPendingResolutionHints()
            pendingParseSource = nil
            pendingPlannedExerciseID = nil
            if clarificationRounds > Self.maxClarificationRounds {
                clearClarificationState()
                lastDeclineReason = nil
                status = .declined
            } else {
                status = .needsClarification(prompt)
            }

        case .declined(let reason):
            // Multi-entry lines first ("bench 135x8 + curl 30x10", a pasted
            // multi-line log): confirm the first segment now and queue the rest.
            // Ahead of the cardio check on purpose — "bench 135x8 bike 20 min"
            // must become a bench draft *plus* a queued bout, not one cardio
            // proposal that silently swallows the bench.
            if splitIntoQueuedEntries(input) { return }
            // Cardio next: the set/rep schema can't hold duration/distance, so a
            // line with a cardio signal ("bike 30 min", "ran 5k") becomes a cardio
            // bout the user confirms — never a guessed weight/reps, never a dead-end.
            if let cardio = CardioParser.parse(input) {
                pendingCardio = cardio
                pending = nil
                clearPendingResolutionHints()
                pendingParseSource = nil
                pendingPlannedExerciseID = nil
                clearClarificationState()
                lastDeclineReason = nil
                status = .idle
                return
            }
            // Best-effort, never a dead-end: salvage an editable draft from the
            // line whenever we honestly can — a recognized lift, a weight in any
            // word order, set/rep counts however phrased — and drop into the
            // confirm card with the fields we *could* read. The user fixes the
            // rest there (reps, exercise, swap sets⇄reps). Only the reasons where
            // a draft would lie keep their guided card: a rep range (pick a count)
            // and multi-exercise (we'd silently lose a lift). This is the whole
            // reason the on-device model exists — and when it isn't present, this
            // forgiving recovery stands in.
            if let recovered = recoveredDraft(from: input, reason: reason) {
                let planned = applySelectedPlannedExerciseIfNeeded(to: recovered.sets)
                pending = WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: applyBodyweightDefault(to: planned.sets))
                pendingPlannedExerciseID = planned.loggedRowID
                pendingParseSource = nil   // neither grammar nor FM produced this; it's a recovery
                refreshPendingExerciseResolution()
                clearClarificationState()
                lastDeclineReason = nil
                status = .idle
                return
            }
            pending = nil
            clearPendingResolutionHints()
            pendingParseSource = nil
            pendingPlannedExerciseID = nil
            clearClarificationState()
            lastDeclineReason = reason
            status = .declined
        }
    }

    // MARK: - Multi-entry split + queue

    /// Re-entrancy guard for `splitIntoQueuedEntries`: applying a segment runs
    /// back through `apply`, which must not try to split again.
    private var isApplyingSegment = false

    /// Treat a declined line as several entries in one breath, when that's what
    /// it is. Splits into candidate segments (`EntrySplitter`) and — only when
    /// **every** segment independently parses, reads as cardio, or recovers into
    /// an honest draft — confirms the first and queues the rest. All-or-nothing:
    /// if any part of the line is unreadable, nothing is split, so no part of
    /// what the user typed can be silently dropped.
    private func splitIntoQueuedEntries(_ input: String) -> Bool {
        guard !isApplyingSegment else { return false }
        let segments = EntrySplitter.segments(input)
        guard segments.count >= 2, segments.allSatisfy(isLoggableSegment) else { return false }
        queuedEntries = Array(segments.dropFirst())
        isApplyingSegment = true
        defer { isApplyingSegment = false }
        applySegment(segments[0])
        return true
    }

    /// Whether one segment, on its own, would land somewhere real: a confident
    /// deterministic parse, a cardio bout, or an honest forgiving recovery.
    private func isLoggableSegment(_ segment: String) -> Bool {
        if let sets = DeterministicParser.parse(segment, defaultUnit: UnitPreferences.current()),
           !sets.isEmpty { return true }
        if CardioParser.parse(segment) != nil { return true }
        return recoveredDraft(from: segment,
                              reason: DeterministicParser.diagnoseDecline(segment)) != nil
    }

    /// Run one segment back through the decline pipeline it came from. The
    /// deterministic grammar gets first shot (a clean "curl 30x10" becomes a
    /// confident draft); anything else re-enters `apply`'s decline branch,
    /// where the cardio and forgiving-recovery paths do their usual work. The
    /// FM layer isn't re-consulted per segment — it already saw the full line.
    private func applySegment(_ segment: String) {
        if let sets = DeterministicParser.parse(segment, defaultUnit: UnitPreferences.current()),
           !sets.isEmpty {
            apply(.draft(WorkoutParseResult(sets: sets, source: .deterministic)), input: segment)
        } else {
            apply(.declined(reason: DeterministicParser.diagnoseDecline(segment)), input: segment)
        }
    }

    /// Pop the next queued segment (if any) into the input box after a save, so
    /// the rest of a multi-entry line takes its turn. The user submits it like
    /// anything else — nothing auto-saves.
    private func advanceEntryQueue() {
        inputText = queuedEntries.first ?? ""
        if !queuedEntries.isEmpty { queuedEntries.removeFirst() }
    }

    /// Salvage an editable draft from a line the parser declined, so the user lands
    /// on the confirm card (and fixes what's missing) instead of a dead-end. Returns
    /// nil only when a draft would be dishonest — genuine non-workout prose or a
    /// multi-exercise line the splitter couldn't take apart (we'd silently drop a
    /// lift). A rep range recovers with reps left unset — never a picked endpoint.
    ///
    /// What it reads, best-effort:
    ///   • the leading text as the exercise — recognized → its canonical, unknown →
    ///     a brand-new custom lift (the confirm card still offers "Did you mean…"
    ///     near-neighbors and a "New exercise" notice, so assignment never fails);
    ///   • a confident trailing weight when present ("bench 135", "frobnicator 135");
    ///   • set/rep counts for the ambiguous triple form ("8x3x4" → 8×3, one tap to
    ///     swap), the natural extension of the sets-vs-reps ambiguity.
    ///
    /// Reps stay UNSET (0) whenever they weren't actually read, so Save stays
    /// disabled until the user confirms a real count — recovery never fabricates
    /// reps, RIR, or load.
    private func recoveredDraft(from rawInput: String, reason: ParseDeclineReason?) -> WorkoutDraft? {
        switch reason {
        case .multiExercise:
            // A single-card draft would silently lose a lift, and the
            // split-and-queue path already had its chance — if it couldn't
            // split safely, the guided card is the honest answer.
            return nil
        case .repRange, .cardio, .incompleteWeight, .ambiguousTripleX, .none:
            // A rep range recovers with reps left UNSET (the forgiving parser
            // consumes the range without picking an endpoint), so the user
            // chooses the count on the card and Save stays disabled until then.
            break
        }

        // The forgiving extractor reads weight/unit/sets/reps/name in any order,
        // tolerates filler, defaults bodyweight lifts to BW, and cleans punctuation
        // off the name ("chinups," → "chinups"). Reps it didn't read stay 0, the
        // unset sentinel, so Save stays disabled until the user confirms a count —
        // recovery never fabricates reps, RIR, or load.
        guard let sets = ForgivingParser.parse(rawInput, defaultUnit: UnitPreferences.current()),
              !sets.isEmpty else { return nil }

        let name = sets.first?.exerciseName ?? ""
        let hasWeight = (sets.first?.weight ?? 0) > 0
        let hasExplicitReps = sets.contains { WorkoutValidator.repsRange.contains($0.reps) }
        let hasStructure = sets.count > 1 || hasExplicitReps

        // Gate: only recover when there's a real logging signal — a recognizable
        // lift, a weight to anchor on, or an explicit set/rep structure. Genuine
        // prose ("did a great workout") has none of these and declines cleanly
        // instead of becoming a phantom set. An explicit structure recovers even
        // with no name — a pure scheme like "8x3x4" lands as a nameless draft the
        // user names, exactly like "3x10". We draft with the *typed* name and let
        // `refreshPendingExerciseResolution` propose near-neighbors / a new-exercise
        // notice — never a silent rename.
        guard isRecoverableExercise(name, hasWeight: hasWeight) || hasStructure else {
            return nil
        }
        return WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: sets)
    }

    /// Whether a declined line's leading text is a plausible exercise worth
    /// recovering into a draft — rather than prose we'd be inventing a set from.
    /// True when a confident weight anchors it as a log, the name resolves
    /// (exact/alias), or it fuzzily resembles a known lift. Recovery always drafts
    /// with the *typed* name and lets the confirm card propose near-neighbors, so
    /// this only gates *whether* to recover, never *what to rename to*.
    private func isRecoverableExercise(_ name: String, hasWeight: Bool) -> Bool {
        guard name.count >= 2 else { return false }
        if hasWeight { return true }
        if ((try? store.resolveExercise(name)) ?? nil) != nil { return true }
        if let best = (try? store.suggestExercisesFuzzy(for: name, limit: 1))?.first,
           best.score >= WorkoutStore.semanticEscalationThreshold {
            return true
        }
        return false
    }

    /// Whether the pending entry's sets and reps can be reinterpreted as each
    /// other. True when every set shares one rep count and *both* the current set
    /// count and rep count are valid in the opposite role — so the swap can never
    /// produce an unsavable draft — and they actually differ (a swap of N×N is a
    /// no-op). The confirm card shows the swap control only when this holds.
    var pendingCanSwapSetsReps: Bool {
        guard pendingRepsAreUniform, pendingSetsAreHomogeneous,
              let reps = pending?.sets.first?.reps, reps > 0 else { return false }
        let setCount = pendingSetCount
        guard setCount != reps else { return false }
        return WorkoutValidator.repsRange.contains(setCount) && (1...99).contains(reps)
    }

    /// Whether the pending entry's sets are identical apart from their (uniform)
    /// reps — same weight, unit, load, RIR, type, and notes. Swap rebuilds every
    /// set from the first, so it's lossless only when there's nothing per-set to
    /// lose. Every set mutator is entry-wide today, so this always holds for a
    /// uniform draft; the guard keeps swap honest if per-set editing is ever added.
    private var pendingSetsAreHomogeneous: Bool {
        guard let sets = pending?.sets, let first = sets.first else { return false }
        // Compare every field swap rewrites from the template (i.e. all but reps),
        // so the gate exactly matches what `swapSetsAndReps()` would overwrite.
        return sets.allSatisfy {
            $0.exerciseName == first.exerciseName && $0.weight == first.weight
                && $0.unit == first.unit && $0.loadKind == first.loadKind
                && $0.rir == first.rir && $0.setType == first.setType
                && $0.notes == first.notes && $0.sourceText == first.sourceText
        }
    }

    /// Reinterpret which number is sets and which is reps — the headline
    /// flexibility fix. "5x3" parses as a best guess (5 sets × 3 reps); one tap
    /// here makes it 3 sets × 5 reps. Acts only on a uniform-rep draft
    /// (`pendingCanSwapSetsReps`), preserving each set's weight/unit/load/RIR/
    /// type/name. No-op otherwise.
    func swapSetsAndReps() {
        guard pendingCanSwapSetsReps,
              var draft = pending,
              let template = draft.sets.first else { return }
        let newReps = draft.sets.count
        let newSetCount = template.reps
        draft.sets = (0..<newSetCount).map { _ in
            SetDraft(exerciseName: template.exerciseName, weight: template.weight,
                     unit: template.unit, loadKind: template.loadKind, reps: newReps,
                     rir: template.rir, setType: template.setType,
                     notes: template.notes, sourceText: template.sourceText)
        }
        pending = draft
    }

    private func clearClarificationState() {
        clarificationInput = nil
        clarificationReplies = []
        clarificationRounds = 0
    }

    /// One entry is one exercise, so a name edit applies to every set in it.
    func setExerciseName(_ name: String) {
        guard var draft = pending else { return }
        for index in draft.sets.indices {
            draft.sets[index].exerciseName = name
        }
        pending = draft
        refreshPendingPlanAttribution()
        refreshPendingExerciseResolution()
    }

    /// The entry's shared load (the parser emits one weight per entry). 0 means
    /// unspecified-or-bodyweight until confirmed.
    var pendingWeight: Double {
        pending?.sets.first?.weight ?? 0
    }

    /// Lets the confirm step turn a bare scheme's placeholder 0 into a real
    /// weight (or leave it 0 for a genuine bodyweight set) before saving.
    func setWeight(_ weight: Double) {
        guard var draft = pending else { return }
        let confirmed = max(0, weight)
        for index in draft.sets.indices {
            draft.sets[index].weight = confirmed
            if confirmed > 0 {
                draft.sets[index].loadKind = .external
            } else if draft.sets[index].loadKind == .external {
                draft.sets[index].loadKind = .unspecified
            }
        }
        pending = draft
    }

    /// Whether every set in the pending entry shares one rep count. The shared
    /// Reps editor is only safe to show when they do (including the all-unset
    /// recovery case) — a parsed entry with uneven reps like 8,8,7 would be
    /// silently flattened by one shared field, so the card hides it and leaves
    /// the per-set summary as the source of truth.
    var pendingRepsAreUniform: Bool {
        guard let sets = pending?.sets, let first = sets.first?.reps else { return false }
        return sets.allSatisfy { $0.reps == first }
    }

    /// The pending entry's shared rep count, or nil when it hasn't been set yet
    /// (a recovered name-only draft, where the parser couldn't read reps) or when
    /// the sets have uneven reps. nil renders as an empty field so the user fills
    /// it in rather than seeing a misleading "0".
    var pendingReps: Int? {
        guard pendingRepsAreUniform, let reps = pending?.sets.first?.reps, reps > 0 else { return nil }
        return reps
    }

    /// Let the confirm step fill in (or correct) the rep count for a draft the
    /// parser couldn't fully read. Applied to every set in the entry, mirroring
    /// the shared weight field — one entry is one exercise. nil clears it back to
    /// the unset sentinel so Save re-disables.
    func setReps(_ reps: Int?) {
        guard var draft = pending else { return }
        let value = max(0, reps ?? 0)
        for index in draft.sets.indices {
            draft.sets[index].reps = value
        }
        pending = draft
    }

    /// Append a set to the pending entry by duplicating the last one, so the new
    /// set inherits the weight/reps/unit/load the user has already dialed in.
    func addSet() {
        guard var draft = pending, let template = draft.sets.last else { return }
        draft.sets.append(SetDraft(exerciseName: template.exerciseName,
                                   weight: template.weight,
                                   unit: template.unit,
                                   loadKind: template.loadKind,
                                   reps: template.reps,
                                   rir: template.rir,
                                   setType: template.setType,
                                   notes: template.notes,
                                   sourceText: template.sourceText))
        pending = draft
    }

    /// Drop the last set. Keeps at least one — an entry with zero sets isn't a
    /// workout, and `removeSet` is the inverse of `addSet`, not a discard.
    func removeSet() {
        guard var draft = pending, draft.sets.count > 1 else { return }
        draft.sets.removeLast()
        pending = draft
    }

    /// The number of sets in the pending entry, for the +/- stepper on the
    /// confirm card.
    var pendingSetCount: Int {
        pending?.sets.count ?? 0
    }

    /// The pending entry's shared unit (the parser emits one unit per entry).
    /// Defaults to `.lb` when there's no pending draft.
    var pendingUnit: WeightUnit {
        pending?.sets.first?.unit ?? .lb
    }

    /// Confirm-card unit toggle. Switching unit here changes only what's
    /// being saved now — the parser is unchanged. This is the safety valve for
    /// the high-severity finding: a kg user typing "100x5" can flip the toggle
    /// to kg before saving instead of having 100 lb persisted silently.
    func setUnit(_ unit: WeightUnit) {
        guard var draft = pending else { return }
        for index in draft.sets.indices {
            draft.sets[index].unit = unit
        }
        pending = draft
    }

    func save() {
        guard let draft = pending else { return }
        // Reconcile first so a stale open session (e.g. left open overnight) is
        // finished and this set opens a fresh one rather than landing in yesterday.
        // If reconcile detected a stale session but couldn't close it, refuse to
        // save rather than let the store adopt it and merge across days.
        guard reconcileActiveSession() else {
            status = .failed("Couldn't close your previous workout. Try again.")
            return
        }
        do {
            let result = try store.save(draft, into: activeSessionID)
            activeSessionID = result.sessionID
            activeSessionSetCount = (try? store.setCount(inSession: result.sessionID))
                ?? (activeSessionSetCount + result.setIDs.count)
            status = .saved(result.setIDs.count)
            lastAchievements = result.achievements
            // Remember exactly which rows the just-shown "saved N sets" notice
            // refers to, so a single Undo tap can delete them. Cleared by the
            // next parse, discard, or save.
            lastSaveUndoToken = UndoToken(sessionID: result.sessionID, setIDs: result.setIDs)
            // A save may have created a new canonical; rebuild the semantic cache so
            // Layer 3 can consider it next time.
            invalidateSemanticCache()

            if let pendingPlannedExerciseID {
                incrementLoggedCount(for: pendingPlannedExerciseID, by: result.setIDs.count)
            }
            pendingPlannedExerciseID = nil
            pending = nil
            clearPendingResolutionHints()
            pendingParseSource = nil
            advanceEntryQueue()   // next segment of a multi-entry line, or ""
            WidgetRefresher.reload()   // the widget shows the open session's set count
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    /// Undo the most recent save: delete every set the visible "saved N sets"
    /// notice refers to, atomically. The store wraps all deletes in one
    /// transaction (`deleteSets`), so a partial failure rolls back — the user
    /// either sees the entry fully undone *or* the failure message with the
    /// undo button still available to retry. The token is cleared **after**
    /// the deletes succeed (the audit caught this — otherwise an in-flight
    /// failure would leave the user with no retry path).
    func undoLastSave() {
        guard let token = lastSaveUndoToken else { return }
        do {
            try store.deleteSets(token.setIDs)
            lastSaveUndoToken = nil
            // Refresh the active-session banner: the batch delete retires an
            // empty session, so a single-set save that opened a fresh session
            // leaves no active workout to show.
            if let count = try? store.setCount(inSession: token.sessionID), count > 0 {
                activeSessionSetCount = count
                activeSessionID = token.sessionID
            } else {
                clearActiveSession()
            }
            lastAchievements = []
            status = .idle
            WidgetRefresher.reload()
        } catch {
            // Keep `lastSaveUndoToken` so the user can tap Undo again to retry
            // the (rolled-back) batch instead of being stranded.
            status = .failed(Self.message(for: error))
        }
    }

    /// Close the active workout, attaching the optional feel / deload / notes the
    /// user picked at finish. Returns an error message on failure (nil on success)
    /// so the finish sheet can keep the entered metadata and stay open, matching
    /// the History editors.
    @discardableResult
    func finishWorkout(feel: SessionFeel?, isDeload: Bool, notes: String?) -> String? {
        guard let id = activeSessionID else { return nil }
        // Capture the session's real start before we close it; the end is now. Only
        // a session with sensible bounds is mirrored to Health (never fabricated).
        let start = (try? store.currentOpenSession())?.startedAt
        let end = Date()
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.finishSession(id, endedAt: end, name: nil,
                                    notes: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                                    feel: feel, isDeload: isDeload)
            clearActiveSession()
            status = .idle
            // Best-effort and non-blocking: write one Apple Health workout for the
            // finished session if the user opted in, then reload the widget so it
            // shows this as the last workout. The health coordinator applies the
            // toggle + permission gates; we only supply real bounds.
            if let task = workoutFinish.finalize(start: start, end: end) {
                pendingHealthWrite = task
            }
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// Adopt the open session as active, or auto-finish it if it's stale (a
    /// different local day, or idle past the gap) so it can't eat today's sets.
    /// Safe to call on appear and before each save. Read/reconcile failures are
    /// swallowed — they must never block logging.
    /// Returns whether it's safe to log now. It's unsafe only in one case: a stale
    /// session was detected but couldn't be retired — in which case the caller must
    /// not save, or `save(_:into:nil)` would adopt that very stale session and merge
    /// today's set into yesterday's workout.
    @discardableResult
    func reconcileActiveSession(now: Date = Date()) -> Bool {
        let open: OpenSession?
        do {
            open = try store.currentOpenSession()
        } catch {
            // Couldn't even read the open session — nothing stale was retired, so
            // clear state and let logging proceed best-effort.
            clearActiveSession()
            log("reconcile read failed", error)
            return true
        }
        guard let open else { clearActiveSession(); return true }

        switch sessionReconciler.decide(open, now: now) {
        case .adopt(let session):
            activeSessionID = session.id
            activeSessionSetCount = session.setCount
            return true
        case .retire(let session):
            do {
                try store.finishSession(session.id, name: nil, notes: nil, feel: nil, isDeload: false)
                clearActiveSession()
                return true
            } catch {
                clearActiveSession()
                log("reconcile could not retire stale session", error)
                return false
            }
        }
    }

    private func clearActiveSession() {
        activeSessionID = nil
        activeSessionSetCount = 0
    }

    private func log(_ message: String, _ error: Error) {
        #if DEBUG
        print("[TodayModel] \(message): \(error)")
        #endif
    }

    func discard() {
        invalidateInFlightParse()
        pending = nil
        pendingCardio = nil
        queuedEntries = []
        clearPendingResolutionHints()
        pendingParseSource = nil
        pendingPlannedExerciseID = nil
        clearClarificationState()
        lastSaveUndoToken = nil
        inputText = ""
        status = .idle
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        status = .idle
    }

    // MARK: - Cardio confirm + save

    /// Default a load-less, unspecified set to bodyweight when the exercise is a
    /// movement that's almost always bodyweight (chin-up, push-up, dip, …). Keeps
    /// `.external` (a weighted variant) and already-confirmed loads untouched. The
    /// honest fix for "chin up 3x10" reading as "unspecified × —" instead of "BW".
    private func applyBodyweightDefault(to sets: [SetDraft]) -> [SetDraft] {
        guard let name = sets.first?.exerciseName,
              ForgivingParser.likelyBodyweightExercise(name) else { return sets }
        return sets.map { set in
            guard set.loadKind == .unspecified, set.weight == 0 else { return set }
            var copy = set
            copy.loadKind = .bodyweight
            return copy
        }
    }

    /// The pending cardio bout's activity name (empty when there's no bout).
    var pendingCardioActivity: String { pendingCardio?.activity ?? "" }

    func setCardioActivity(_ name: String) {
        guard var cardio = pendingCardio else { return }
        cardio.activity = name
        pendingCardio = cardio
    }

    /// Duration as whole minutes for the confirm card's editor; nil when unset or
    /// when the bout isn't a whole number of minutes. Sub-minute durations
    /// ("run 45s") aren't shown as a rounded "1" — that would both misrepresent
    /// the value and, on edit, silently rewrite 45s to 60s. The exact
    /// `durationSeconds` is preserved on save unless the user types a minutes value.
    var pendingCardioMinutes: Int? {
        guard let seconds = pendingCardio?.durationSeconds, seconds > 0, seconds % 60 == 0 else { return nil }
        return seconds / 60
    }

    func setCardioMinutes(_ minutes: Int?) {
        guard var cardio = pendingCardio else { return }
        if let minutes, minutes > 0 {
            cardio.durationSeconds = minutes * 60
        } else {
            cardio.durationSeconds = nil
        }
        pendingCardio = cardio
    }

    var pendingCardioDistance: Double? { pendingCardio?.distance }

    func setCardioDistance(_ distance: Double?) {
        guard var cardio = pendingCardio else { return }
        if let distance, distance > 0 {
            cardio.distance = distance
            if cardio.distanceUnit == nil { cardio.distanceUnit = .km }
        } else {
            cardio.distance = nil
            cardio.distanceUnit = nil
        }
        pendingCardio = cardio
    }

    var pendingCardioDistanceUnit: CardioDistanceUnit { pendingCardio?.distanceUnit ?? .km }

    func setCardioDistanceUnit(_ unit: CardioDistanceUnit) {
        guard var cardio = pendingCardio else { return }
        cardio.distanceUnit = unit
        pendingCardio = cardio
    }

    /// Cardio is always savable once proposed — the activity has a guaranteed
    /// fallback and metrics are optional. Mirrors the "never fail" contract.
    var canSaveCardio: Bool {
        guard let cardio = pendingCardio else { return false }
        return !cardio.activity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Write the pending cardio bout through the store's one cardio write path.
    /// Independent of the strength session — cardio is logged separately (PR's
    /// banner copy made real).
    func saveCardio() {
        guard let draft = pendingCardio else { return }
        do {
            _ = try store.saveCardio(draft)
            let clean = CardioValidator.normalized(draft)
            let summary = CardioFormat.summary(durationSeconds: clean.durationSeconds,
                                               distance: clean.distance,
                                               distanceUnit: clean.distanceUnit)
            status = .savedCardio("\(clean.activity) · \(summary)")
            pendingCardio = nil
            advanceEntryQueue()   // next segment of a multi-entry line, or ""
            WidgetRefresher.reload()
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    func discardCardio() {
        pendingCardio = nil
        queuedEntries = []
        inputText = ""
        status = .idle
    }

    func startPlan() {
        let parsed = Self.parsePlanText(planText)
        plannedExercises = parsed
        selectedPlannedExerciseID = parsed.first?.id
        mode = .workoutPlan
        status = .idle
        persistActivePlan()
    }

    func clearActivePlan() {
        plannedExercises = []
        selectedPlannedExerciseID = nil
        inputText = ""
        pending = nil
        queuedEntries = []
        clearPendingResolutionHints()
        pendingParseSource = nil
        pendingPlannedExerciseID = nil
        clearClarificationState()
        persistActivePlan()
    }

    func selectPlannedExercise(_ id: UUID) {
        guard plannedExercises.contains(where: { $0.id == id }) else { return }
        selectedPlannedExerciseID = id
        inputText = ""
        pending = nil
        queuedEntries = []
        clearPendingResolutionHints()
        pendingParseSource = nil
        pendingPlannedExerciseID = nil
        clearClarificationState()
        status = .idle
        persistActivePlan()
    }

    func saveCurrentPlan() {
        let text = planText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.parsePlanText(text).isEmpty else { return }
        let fallback = selectedSavedPlanID.flatMap { id in savedPlans.first { $0.id == id }?.name }
        let name = Self.collapsedWhitespace(planName).isEmpty ? (fallback ?? "Workout Plan") : Self.collapsedWhitespace(planName)
        if let selectedSavedPlanID,
           let index = savedPlans.firstIndex(where: { $0.id == selectedSavedPlanID }) {
            savedPlans[index].name = name
            savedPlans[index].text = text
        } else {
            let plan = SavedPlan(id: UUID(), name: name, text: text)
            savedPlans.append(plan)
            selectedSavedPlanID = plan.id
        }
        persistSavedPlans()
        persistActivePlan()
    }

    func selectSavedPlan(_ id: UUID) {
        guard let plan = savedPlans.first(where: { $0.id == id }) else { return }
        selectedSavedPlanID = plan.id
        planName = plan.name
        planText = plan.text
        startPlan()
    }

    static func parsePlanText(_ text: String) -> [PlannedExercise] {
        text.components(separatedBy: .newlines)
            .compactMap(normalizePlanLine)
            .map { PlannedExercise(id: UUID(), name: $0) }
    }

    /// Maps the strict-saver errors to plain language. The save path is the only
    /// place a draft can be rejected once confirmed, so these are the messages a
    /// user actually sees.
    static func message(for error: Error) -> String {
        guard let parseError = error as? ParseError else { return "Couldn't save. Try again." }
        switch parseError {
        case .noSets: return "Nothing to save yet."
        case .emptyExerciseName: return "Name the exercise first."
        case .badWeight: return "That weight doesn't look right."
        case .badReps: return "Reps should be between \(WorkoutValidator.minReps) and \(WorkoutValidator.maxReps)."
        case .badRIR: return "RIR should be between 0 and 10."
        }
    }

    private func applySelectedPlannedExerciseIfNeeded(to sets: [SetDraft]) -> (sets: [SetDraft], loggedRowID: UUID?) {
        guard mode == .workoutPlan,
              let selected = selectedPlannedExercise else {
            return (sets, nil)
        }
        let parsedName = Self.collapsedWhitespace(sets.first?.exerciseName ?? "")
        if parsedName.isEmpty {
            return (sets.map { set in
                var copy = set
                copy.exerciseName = selected.name
                return copy
            }, selected.id)
        }
        guard namesMatch(parsedName, selected.name) else {
            // Typed exercise is more specific than the selected row; never silently overwrite it.
            return (sets, nil)
        }
        return (sets.map { set in
            var copy = set
            copy.exerciseName = selected.name
            return copy
        }, selected.id)
    }

    private func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = Self.collapsedWhitespace(lhs).lowercased()
        let right = Self.collapsedWhitespace(rhs).lowercased()
        if left == right { return true }
        do {
            guard let leftID = try store.resolveExercise(left),
                  let rightID = try store.resolveExercise(right) else { return false }
            return leftID == rightID
        } catch {
            return false
        }
    }

    private func incrementLoggedCount(for id: UUID, by count: Int) {
        guard let index = plannedExercises.firstIndex(where: { $0.id == id }) else { return }
        plannedExercises[index].loggedSetCount += count
        persistActivePlan()
    }

    private func refreshPendingPlanAttribution() {
        guard mode == .workoutPlan,
              let selected = selectedPlannedExercise,
              let exerciseName = pending?.sets.first?.exerciseName,
              namesMatch(exerciseName, selected.name) else {
            pendingPlannedExerciseID = nil
            return
        }
        pendingPlannedExerciseID = selected.id
    }

    /// Clears the confirm-card resolution hints — the new-exercise notice, the
    /// fuzzy suggestions, and the "last time" snapshot. They all describe the
    /// pending exercise, so they always appear and disappear together.
    private func clearPendingResolutionHints() {
        pendingCreatesNewExercise = false
        pendingSuggestions = []
        lastTime = nil
    }

    private func refreshPendingExerciseResolution() {
        let name = pendingExerciseName
        guard !Self.collapsedWhitespace(name).isEmpty else {
            clearPendingResolutionHints()
            return
        }
        let resolved = (try? store.resolveExercise(name)) ?? nil
        pendingCreatesNewExercise = resolved == nil
        // Only consult the suggesters when exact + alias both miss, so an aliased lift
        // is never "corrected" onto a different one.
        pendingSuggestions = resolved == nil ? suggestions(for: name) : []
        // "Last time" only makes sense for a known lift; an unresolved/new name has
        // no prior finished session to show.
        lastTime = resolved.flatMap { (try? store.lastTime(forExercise: $0)) ?? nil }
    }

    /// Layer 2 → Layer 3 (§1.1): fuzzy candidates, then — only when fuzzy is
    /// low-confidence (best < ~0.85) — the optional semantic layer, merged in for any
    /// canonical fuzzy didn't already surface. Semantic is opportunistic: when the
    /// embedding isn't ready it contributes nothing and the result is exactly the old
    /// fuzzy list. Still proposes; the user confirms; distinct canonicals never merge.
    private func suggestions(for name: String) -> [ExerciseSuggestion] {
        let fuzzy = (try? store.suggestExercisesFuzzy(for: name)) ?? []
        let bestFuzzy = fuzzy.first?.score ?? 0
        guard bestFuzzy < WorkoutStore.semanticEscalationThreshold else { return fuzzy }

        let semantic = semanticSuggester.suggestions(for: name, among: semanticCandidates())
        guard !semantic.isEmpty else { return fuzzy }
        // Union by exercise id, fuzzy first (deterministic Layer-2 workhorse), then any
        // new semantic-only canonicals — so embeddings *add* options, never displace.
        let seen = Set(fuzzy.map(\.exerciseID))
        return fuzzy + semantic.filter { !seen.contains($0.exerciseID) }
    }

    /// The canonical vectors for the semantic layer, embedded once and cached. Returns
    /// `[]` cheaply when embeddings aren't ready — **without** caching, so a later run
    /// (assets finished downloading) can still build the cache instead of freezing
    /// empty. The cache is invalidated when a save may have created a new canonical
    /// (see `invalidateSemanticCache`), so Layer 3 isn't blind to fresh lifts.
    private func semanticCandidates() -> [SemanticSuggester.Candidate] {
        guard semanticSuggester.embedding.isReady else { return [] }
        if let cache = semanticCandidateCache { return cache }
        let canonicals = (try? store.exerciseCanonicals()) ?? []
        let built: [SemanticSuggester.Candidate] = canonicals.compactMap { row in
            guard let vector = semanticSuggester.embedding.vector(for: row.name) else { return nil }
            return SemanticSuggester.Candidate(exerciseID: row.id, canonicalName: row.name,
                                               familyKey: row.familyKey, vector: vector)
        }
        semanticCandidateCache = built
        return built
    }

    /// Drop the cached canonical vectors so they're rebuilt on the next semantic
    /// lookup. Called after a save, which can add a new exercise the cache wouldn't
    /// otherwise know about.
    private func invalidateSemanticCache() {
        semanticCandidateCache = nil
    }

    /// Apply a "Did you mean …?" suggestion — sets the pending name to that
    /// canonical (which then resolves exactly, clearing the new-exercise notice).
    func applySuggestion(_ suggestion: ExerciseSuggestion) {
        setExerciseName(suggestion.canonicalName)
    }

    /// Compute live exercise-name suggestions for the leading text span of
    /// `inputText` (the portion before any numbers/operators). A tap rewrites
    /// that span; the trailing spec (`135x8`) is preserved untouched. Runs
    /// synchronously on the main actor since the fuzzy search is fast — the
    /// store read is indexed and capped to a small canonical set.
    private func refreshInputAutocomplete() {
        let leading = TodayInputTokenizer.leadingNamePrefix(inputText)
        // Two letters is the smallest prefix where the fuzzy metric reliably
        // beats the rest of the canonical library — below that the chips would
        // shuffle unhelpfully on every keystroke.
        guard leading.count >= 2 else { inputSuggestions = []; return }
        let hits = (try? store.suggestExercisesFuzzy(for: leading, limit: 4)) ?? []
        // An exact resolve already covers the name — don't propose synonyms of
        // a lift the user clearly already typed by name.
        if let resolved = try? store.resolveExercise(leading),
           hits.first?.exerciseID == resolved, hits.first?.score == 1.0 {
            inputSuggestions = []
        } else {
            inputSuggestions = hits
        }
    }

    /// Tap a leading-input suggestion: rewrite the name span only, preserving
    /// any trailing spec the user already typed (`bench` → tap → "bench press"
    /// without losing `135x8`). Uses the raw `String.Index` of the core boundary
    /// — not the *length* of a normalized prefix — so leading/internal
    /// whitespace (`"  bench 135x8"`, `"incline   bench 135x8"`) doesn't
    /// desync the rewrite.
    func applyInputSuggestion(_ suggestion: ExerciseSuggestion) {
        let endIndex = TodayInputTokenizer.leadingNamePrefixEndIndex(in: inputText)
        let tail = inputText[endIndex...]
        let needsSpace = !tail.isEmpty && !(tail.first?.isWhitespace ?? false)
        inputText = suggestion.canonicalName + (needsSpace ? " " : "") + tail
    }

    private static func normalizePlanLine(_ raw: String) -> String? {
        var line = raw.replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        line = stripLeadingListMarker(from: line)
        line = collapsedWhitespace(line)
        return line.isEmpty ? nil : line
    }

    private static func stripLeadingListMarker(from line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        if let first = scalars.first,
           ["-", "*", "•", "–", "—"].contains(String(first)),
           scalars.dropFirst().first.map(CharacterSet.whitespaces.contains) == true {
            return String(String.UnicodeScalarView(scalars.dropFirst()))
                .trimmingCharacters(in: .whitespaces)
        }

        var index = scalars.startIndex
        while index < scalars.endIndex, CharacterSet.decimalDigits.contains(scalars[index]) {
            index = scalars.index(after: index)
        }
        guard index > scalars.startIndex,
              index < scalars.endIndex,
              scalars[index] == "." || scalars[index] == ")" else { return line }
        let afterMarker = scalars.index(after: index)
        guard afterMarker < scalars.endIndex,
              CharacterSet.whitespaces.contains(scalars[afterMarker]) else { return line }
        return String(String.UnicodeScalarView(scalars[scalars.index(after: afterMarker)...]))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func collapsedWhitespace(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func restorePlans() {
        isRestoringPlanState = true
        defer { isRestoringPlanState = false }
        if let decoded = planStore.loadSavedPlans() {
            savedPlans = decoded
        }
        if let decoded = planStore.loadActivePlanScaffold() {
            mode = decoded.mode
            planName = decoded.planName
            planText = decoded.planText
            selectedSavedPlanID = decoded.selectedSavedPlanID
            plannedExercises = decoded.plannedExercises
            selectedPlannedExerciseID = decoded.selectedPlannedExerciseID
        }
    }

    private func persistSavedPlans() {
        planStore.saveSavedPlans(savedPlans)
    }

    private func persistActivePlan() {
        guard !isRestoringPlanState else { return }
        planStore.saveActivePlanScaffold(PlanStore.ActivePlanScaffold(
            mode: mode,
            planName: planName,
            planText: planText,
            selectedSavedPlanID: selectedSavedPlanID,
            plannedExercises: plannedExercises,
            selectedPlannedExerciseID: selectedPlannedExerciseID
        ))
    }
}
