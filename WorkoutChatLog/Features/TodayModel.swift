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
        return !pendingExerciseName.trimmingCharacters(in: .whitespaces).isEmpty && !pending.sets.isEmpty
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
        switch outcome {
        case .draft(let result):
            let planned = applySelectedPlannedExerciseIfNeeded(to: result.sets)
            pending = WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: planned.sets)
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
            pending = nil
            clearPendingResolutionHints()
            pendingParseSource = nil
            pendingPlannedExerciseID = nil
            clearClarificationState()
            lastDeclineReason = reason
            status = .declined
        }
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
            inputText = ""
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
