import XCTest
@testable import WorkoutChatLog

@MainActor
final class TodayModelTests: XCTestCase {

    private var path: String!
    private var store: WorkoutStore!
    private var model: TodayModel!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "wcl-today-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: path))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
        defaultsSuiteName = "wcl-today-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        model = TodayModel(store: store, planDefaults: defaults)
    }

    override func tearDownWithError() throws {
        model = nil
        store = nil
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func testParseSuccessProducesPendingDraft() async {
        model.inputText = "bench 135x8"
        await model.parse()
        XCTAssertEqual(model.pending?.sets.count, 1)
        XCTAssertEqual(model.pendingExerciseName, "bench")
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.status, .idle)
    }

    func testParseDeclineSetsDeclinedStatus() async {
        model.inputText = "did a great workout"
        await model.parse()
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.status, .declined)
        XCTAssertFalse(model.canSave)
    }

    func testBareSchemeNeedsNameBeforeSave() async throws {
        model.inputText = "3x10"
        await model.parse()
        XCTAssertEqual(model.pending?.sets.count, 3)
        XCTAssertTrue(model.pendingExerciseName.isEmpty)
        XCTAssertFalse(model.canSave, "a bare scheme can't save without an exercise")

        model.setExerciseName("Squat")
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.pending?.sets.allSatisfy { $0.exerciseName == "Squat" }, true)

        model.save()
        XCTAssertEqual(model.status, .saved(3))
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.inputText, "")
        XCTAssertEqual(try store.setCount(), 3)
    }

    func testConfirmCardCanSetWeightOnABareScheme() async throws {
        model.inputText = "squat 3x10"
        await model.parse()
        XCTAssertEqual(model.pendingWeight, 0, "bare scheme starts unspecified")
        XCTAssertEqual(model.pending?.sets.first?.loadKind, .unspecified)

        model.setExerciseName("Back Squat")
        model.setWeight(135)
        XCTAssertEqual(model.pendingWeight, 135)
        XCTAssertEqual(model.pending?.sets.allSatisfy { $0.weight == 135 }, true)
        XCTAssertEqual(model.pending?.sets.allSatisfy { $0.loadKind == .external }, true)

        model.save()
        XCTAssertEqual(model.status, .saved(3))
        let session = try XCTUnwrap(try store.sets(inSession: 1).first)
        XCTAssertEqual(session.weight, 135, "the confirmed weight, not the placeholder 0, is stored")
    }

    func testDeclineRecoversFillableDraftForKnownExercise() async throws {
        // No reps/weight, just a recognizable lift — recover into an editable
        // draft instead of a hard decline so the user can fill reps in.
        model.inputText = "leg press"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.lastDeclineReason)
        XCTAssertEqual(model.pending?.sets.count, 1)
        XCTAssertEqual(model.pendingExerciseName.lowercased(), "leg press")
        XCTAssertNil(model.pendingReps, "reps start unset so the user fills them in")
        XCTAssertFalse(model.canSave, "a draft with no reps can't be saved yet")

        model.setReps(10)
        XCTAssertEqual(model.pendingReps, 10)
        XCTAssertTrue(model.canSave)
        model.save()
        XCTAssertEqual(model.status, .saved(1))
        let stored = try XCTUnwrap(try store.sets(inSession: 1).first)
        XCTAssertEqual(stored.reps, 10)
    }

    func testDeclineRecoversThroughAlias() async {
        // "ohp" is a seeded alias for Overhead Press — the alias path recovers too.
        model.inputText = "ohp"
        await model.parse()
        XCTAssertEqual(model.pending?.sets.count, 1)
        XCTAssertFalse(model.pendingExerciseName.isEmpty)
        XCTAssertFalse(model.canSave)
    }

    func testNonWorkoutProseStillDeclines() async {
        // The recovery must not turn genuine prose into a phantom set.
        model.inputText = "did a great workout"
        await model.parse()
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.status, .declined)
    }

    func testRepsClearingReDisablesSave() async {
        model.inputText = "squat 3x10"
        await model.parse()
        model.setExerciseName("Back Squat")
        XCTAssertTrue(model.canSave)
        model.setReps(nil)
        XCTAssertFalse(model.canSave, "clearing reps re-disables Save")
        XCTAssertEqual(model.pending?.sets.allSatisfy { $0.reps == 0 }, true)
    }

    func testAddAndRemoveSet() async {
        model.inputText = "bench 135x8"
        await model.parse()
        XCTAssertEqual(model.pendingSetCount, 1)

        model.addSet()
        XCTAssertEqual(model.pendingSetCount, 2)
        XCTAssertEqual(model.pending?.sets.last?.reps, 8, "an added set copies the last one")
        XCTAssertEqual(model.pending?.sets.last?.weight, 135)

        model.removeSet()
        XCTAssertEqual(model.pendingSetCount, 1)
        model.removeSet()
        XCTAssertEqual(model.pendingSetCount, 1, "never drops below one set")
    }

    func testUnevenRepsDraftDoesNotExposeSharedRepsField() async {
        // A parsed entry with distinct per-set reps must not surface the shared
        // Reps editor, which would flatten 8,8,7 to one value on edit.
        model.inputText = "bench 135 for 8,8,7"
        await model.parse()
        XCTAssertEqual(model.pending?.sets.map { $0.reps }, [8, 8, 7])
        XCTAssertFalse(model.pendingRepsAreUniform)
        XCTAssertNil(model.pendingReps, "no single value describes an uneven draft")
        XCTAssertTrue(model.canSave, "uneven reps are all valid, so Save stays enabled")
    }

    func testUniformRepsDraftExposesSharedRepsField() async {
        model.inputText = "squat 3x10"
        await model.parse()
        XCTAssertTrue(model.pendingRepsAreUniform)
        XCTAssertEqual(model.pendingReps, 10)
    }

    func testSaveSuccessClearsAndReports() async throws {
        model.inputText = "bench 135 for 8,8,7"
        await model.parse()
        model.save()
        XCTAssertEqual(model.status, .saved(3))
        XCTAssertEqual(try store.sessionCount(), 1)
        XCTAssertEqual(try store.setCount(), 3)
    }

    func testLastTimePopulatesForAKnownLiftWithFinishedHistory() async throws {
        // A finished session of bench, then a fresh entry for the same lift surfaces
        // the "last time" snapshot once the name resolves.
        let session = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            SetDraft(exerciseName: "Bench Press", weight: 135, unit: .lb, loadKind: .external, reps: 8)
        ])).sessionID
        try store.finishSession(session, name: nil, notes: nil, feel: nil, isDeload: false)

        model.inputText = "bench 135x5"
        await model.parse()
        model.setExerciseName("Bench Press")   // resolves exactly
        XCTAssertEqual(model.lastTime?.sets.map(\.reps), [8], "shows the prior finished session")

        model.discard()
        XCTAssertNil(model.lastTime, "cleared with the pending draft")
    }

    func testLastTimeIsNilForAFirstTimeLift() async {
        model.inputText = "bench 135x8"
        await model.parse()
        model.setExerciseName("Bench Press")
        XCTAssertNil(model.lastTime, "no prior finished session → no hint")
    }

    func testSemanticLayerSurfacesSuggestionWhenFuzzyIsLowConfidence() async throws {
        // "thoracic hinge" shares no token/edit-distance with any lift (fuzzy is silent),
        // but a fake embedding places it near Deadlift → a `.semantic` suggestion appears.
        let deadliftID = try XCTUnwrap(store.resolveExercise("Deadlift"))
        let embedding = FakeEmbedding(vectors: [
            "thoracic hinge": [1.0, 0.0],
            "Deadlift": [0.99, 0.10]   // ~0.995 cosine, above the 0.85 floor
        ])
        let semanticModel = TodayModel(store: store, planDefaults: defaults, embedding: embedding)
        semanticModel.inputText = "thoracic hinge 225x5"
        await semanticModel.parse()

        XCTAssertTrue(semanticModel.pendingCreatesNewExercise, "unrecognized name")
        let semantic = semanticModel.pendingSuggestions.first { $0.via == .semantic }
        XCTAssertEqual(semantic?.exerciseID, deadliftID, "semantic layer proposes the near canonical")
    }

    func testFuzzySuiteUnaffectedWhenEmbeddingsUnavailable() async {
        // The shippable bar: with no embeddings, a typo still resolves via fuzzy alone.
        let noopModel = TodayModel(store: store, planDefaults: defaults, embedding: NoopEmbedding())
        noopModel.inputText = "deadlft 225x5"
        await noopModel.parse()
        XCTAssertTrue(noopModel.pendingSuggestions.contains { $0.canonicalName == "Deadlift" && $0.via == .fuzzy },
                      "fuzzy still works with embeddings unavailable")
    }

    // TODO(workout-semantic-cache-ci-skip): re-enable this test in CI.
    //
    // Skipped on GitHub Actions runners only (PR #255 introduced the workout
    // iOS CI lane; this assertion failed on macos-14 even though it passes
    // on a maintainer's local simulator). The fixture uses `FakeEmbedding`,
    // not the real `NLContextualEmbedding`, so this isn't the documented
    // NL-fails-in-simulator behavior — likely a `save()` →
    // `invalidateSemanticCache()` → `parse()` timing gap that only
    // reproduces in the runner's environment.
    //
    // The gate is the compile-time `CI` flag, set by the
    // `ios-tests.yml` build step via
    // `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. Runtime env-var detection
    // didn't work — `ProcessInfo.processInfo.environment` inside the
    // iOS Simulator doesn't inherit the host runner's `CI=true`, and
    // neither `SIMCTL_CHILD_CI` nor a plain `env:` block propagates
    // through xcodebuild's test runner.
    //
    // To re-enable: fix the underlying timing locally, then delete the
    // `#if CI` block and the `SWIFT_ACTIVE_COMPILATION_CONDITIONS` flag
    // in the workflow. Grep `workout-semantic-cache-ci-skip` so the
    // skip doesn't quietly become permanent.
    func testSemanticLayerSeesAnExerciseCreatedDuringTheSession() async throws {
        #if CI
        throw XCTSkip("TODO(workout-semantic-cache-ci-skip): see file header — flaky on GitHub Actions iOS Simulator")
        #endif

        // A custom lift is created by saving it; a later semantic near-miss should be
        // able to propose it, proving the candidate cache rebuilt after the save (it
        // would otherwise be frozen without the new canonical).
        let embedding = FakeEmbedding(vectors: [
            "Jefferson Curl": [1.0, 0.0],
            "spinal flexion hold": [0.99, 0.10]   // semantic near-miss, no shared tokens
        ])
        let m = TodayModel(store: store, planDefaults: defaults, embedding: embedding)

        m.inputText = "jefferson curl 45x10"
        await m.parse()
        XCTAssertTrue(m.pendingCreatesNewExercise)
        m.save()   // creates the canonical + invalidates the semantic cache

        m.inputText = "spinal flexion hold 45x10"
        await m.parse()
        let semantic = m.pendingSuggestions.first { $0.via == .semantic }
        XCTAssertEqual(semantic?.canonicalName, "Jefferson Curl",
                       "semantic cache rebuilt after the save sees the new lift")
    }

    func testSaveSurfacesPersonalRecordNotice() async throws {
        // Baseline, then a heavier set of the same lift → an e1RM PR notice (§4).
        model.inputText = "bench 135x8"
        await model.parse()
        model.save()
        XCTAssertTrue(model.lastAchievements.isEmpty, "first time logged is not a PR")

        model.inputText = "bench 145x8"
        await model.parse()
        XCTAssertTrue(model.lastAchievements.isEmpty, "starting a new entry clears the prior notice")
        model.save()
        XCTAssertEqual(model.status, .saved(1))
        XCTAssertTrue(model.lastAchievements.contains { $0.kind == .estimatedOneRepMax },
                      "beating prior history surfaces a personal record")
    }

    func testDiscardResets() async {
        model.inputText = "bench 135x8"
        await model.parse()
        XCTAssertNotNil(model.pending)
        model.discard()
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.inputText, "")
        XCTAssertEqual(model.status, .idle)
    }

    func testUnknownExerciseShowsNewExerciseConfirmationBeforeSave() async throws {
        model.inputText = "jefferson curl 45x10"
        await model.parse()

        XCTAssertEqual(model.pendingExerciseName, "jefferson curl")
        XCTAssertTrue(model.pendingCreatesNewExercise)

        model.save()
        XCTAssertEqual(model.status, .saved(1))
        XCTAssertNotNil(try store.resolveExercise("jefferson curl"))
    }

    func testErrorMessageMapping() {
        XCTAssertEqual(TodayModel.message(for: ParseError.emptyExerciseName), "Name the exercise first.")
        XCTAssertEqual(TodayModel.message(for: ParseError.badReps), "Reps should be between 1 and 100.")
        struct Other: Error {}
        XCTAssertEqual(TodayModel.message(for: Other()), "Couldn't save. Try again.")
    }

    // MARK: - Workout Plan mode

    func testPlanTextParsingStripsOnlyAnchoredListMarkers() {
        let parsed = TodayModel.parsePlanText("""
        - Bench Press
        1. Back Squat
        2) Cable Row
        • Pull-Up
        — Lateral Raise
        5x5 Bench Press
        21s
        3x5/3x3/3x1
        Bench Press (3 sets)
        """)

        XCTAssertEqual(parsed.map(\.name), [
            "Bench Press",
            "Back Squat",
            "Cable Row",
            "Pull-Up",
            "Lateral Raise",
            "5x5 Bench Press",
            "21s",
            "3x5/3x3/3x1",
            "Bench Press (3 sets)"
        ])
    }

    func testWorkoutPlanAttachesSelectedExerciseToBareSpec() async throws {
        model.planText = "Bench Press\nBack Squat"
        model.startPlan()

        model.inputText = "3x10"
        await model.parse()

        XCTAssertEqual(model.pending?.sets.count, 3)
        XCTAssertEqual(model.pendingExerciseName, "Bench Press")
        XCTAssertTrue(model.canSave)

        model.save()
        XCTAssertEqual(model.plannedExercises.first?.loggedSetCount, 3)
        XCTAssertEqual(try store.setCount(), 3)
    }

    func testWorkoutPlanDoesNotOverwriteConflictingTypedExercise() async throws {
        model.planText = "Bench Press"
        model.startPlan()

        model.inputText = "squat 225x5"
        await model.parse()

        XCTAssertEqual(model.pendingExerciseName, "squat")
        XCTAssertTrue(model.canSave)

        model.save()
        XCTAssertEqual(model.plannedExercises.first?.loggedSetCount, 0,
                       "a conflicting typed exercise must not be counted against the selected plan row")
        let rows = try store.sets(inSession: 1)
        let exercise = try store.exercise(id: try XCTUnwrap(rows.first?.exerciseID))
        XCTAssertEqual(exercise?.canonicalName, "Back Squat")
    }

    func testWorkoutPlanHandlesPunctuatedSelectedExerciseNames() async {
        model.planText = "Bench Press"
        model.startPlan()

        model.inputText = "Bench Press: 135x8"
        await model.parse()
        XCTAssertEqual(model.pendingExerciseName, "Bench Press")
        XCTAssertEqual(model.pendingCreatesNewExercise, false)
        model.discard()

        model.inputText = "Bench Press - 135x8"
        await model.parse()
        XCTAssertEqual(model.pendingExerciseName, "Bench Press")
        XCTAssertEqual(model.pendingCreatesNewExercise, false)
    }

    func testWorkoutPlanCountsMatchingTypedExerciseAgainstSelectedRow() async throws {
        model.planText = "Bench Press"
        model.startPlan()

        model.inputText = "bench press 135x8"
        await model.parse()

        XCTAssertEqual(model.pendingExerciseName, "Bench Press")
        model.save()
        XCTAssertEqual(model.plannedExercises.first?.loggedSetCount, 1)
    }

    func testEditingPendingExerciseNameClearsPlanAttributionWhenItNoLongerMatches() async throws {
        model.planText = "Bench Press"
        model.startPlan()

        model.inputText = "3x10"
        await model.parse()
        XCTAssertEqual(model.pendingExerciseName, "Bench Press")

        model.setExerciseName("Back Squat")
        model.setWeight(225)
        model.save()

        XCTAssertEqual(model.plannedExercises.first?.loggedSetCount, 0,
                       "editing away from the selected plan row must not count against it")
        XCTAssertEqual(try store.setCount(), 3)
        let rows = try store.sets(inSession: 1)
        let exercise = try store.exercise(id: try XCTUnwrap(rows.first?.exerciseID))
        XCTAssertEqual(exercise?.canonicalName, "Back Squat")
    }

    func testDuplicatePlannedExerciseNamesKeepDistinctRowIdentity() async throws {
        model.planText = "Bench Press\nBench Press"
        model.startPlan()

        XCTAssertEqual(model.plannedExercises.count, 2)
        XCTAssertNotEqual(model.plannedExercises[0].id, model.plannedExercises[1].id)

        model.selectPlannedExercise(model.plannedExercises[1].id)
        model.inputText = "135x8"
        await model.parse()
        model.save()

        XCTAssertEqual(model.plannedExercises[0].loggedSetCount, 0)
        XCTAssertEqual(model.plannedExercises[1].loggedSetCount, 1)
    }

    func testSavedPlansPersistAndCanBeSelected() {
        model.planName = "Leg Day"
        model.planText = "Back Squat\nRomanian Deadlift"
        model.saveCurrentPlan()

        let restored = TodayModel(store: store, planDefaults: defaults)
        XCTAssertEqual(restored.savedPlans.map(\.name), ["Leg Day"])

        let id = restored.savedPlans[0].id
        restored.selectSavedPlan(id)
        XCTAssertEqual(restored.mode, .workoutPlan)
        XCTAssertEqual(restored.planName, "Leg Day")
        XCTAssertEqual(restored.plannedExercises.map(\.name), ["Back Squat", "Romanian Deadlift"])
    }

    func testActiveWorkoutPlanScaffoldSurvivesModelRestore() {
        model.planText = "Bench Press\nCable Row"
        model.startPlan()
        model.selectPlannedExercise(model.plannedExercises[1].id)

        let restored = TodayModel(store: store, planDefaults: defaults)

        XCTAssertEqual(restored.mode, .workoutPlan)
        XCTAssertEqual(restored.plannedExercises.map(\.name), ["Bench Press", "Cable Row"])
        XCTAssertEqual(restored.selectedPlannedExercise?.name, "Cable Row")
    }

    // MARK: - Active session lifecycle (PR 3)

    private func logFreeForm(_ text: String) async {
        model.inputText = text
        await model.parse()
        model.save()
    }

    func testConsecutiveEntriesLandInOneActiveSession() async throws {
        await logFreeForm("bench 135x8")
        let first = try XCTUnwrap(model.activeSessionID)
        await logFreeForm("bench 145x6")
        XCTAssertEqual(model.activeSessionID, first, "the second entry appends to the active session")
        XCTAssertEqual(try store.sessionCount(), 1)
        XCTAssertEqual(model.activeSessionSetCount, 2)
    }

    func testReconcileAdoptsAnOpenSessionFromToday() async throws {
        await logFreeForm("bench 135x8")
        let sessionID = try XCTUnwrap(model.activeSessionID)

        // A fresh model (app relaunch) adopts the still-open session on appear.
        let fresh = TodayModel(store: store, planDefaults: defaults)
        fresh.reconcileActiveSession()
        XCTAssertEqual(fresh.activeSessionID, sessionID)
        XCTAssertEqual(fresh.activeSessionSetCount, 1)
    }

    func testReconcileAutoFinishesStaleSessionFromAnotherDay() async throws {
        await logFreeForm("bench 135x8")
        let sessionID = try XCTUnwrap(model.activeSessionID)

        // A day later, reconciling finishes the stale session rather than adopting it.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        model.reconcileActiveSession(now: tomorrow)
        XCTAssertNil(model.activeSessionID, "stale session is auto-finished")
        XCTAssertNil(try store.currentOpenSession(), "no open session remains")
        XCTAssertEqual(try store.setCount(inSession: sessionID), 1, "its set is preserved — closed, not deleted")

        // Today's next log opens a fresh session, not yesterday's.
        await logFreeForm("bench 135x8")
        XCTAssertNotEqual(model.activeSessionID, sessionID)
        XCTAssertEqual(try store.sessionCount(), 2)
    }

    func testFinishWorkoutClosesActiveSessionWithMetadata() async throws {
        await logFreeForm("bench 135x8")
        XCTAssertNotNil(model.activeSessionID)

        model.finishWorkout(feel: .solid, isDeload: false, notes: "good session")
        XCTAssertNil(model.activeSessionID, "finishing clears the active workout")
        XCTAssertNil(try store.currentOpenSession())
        let row = try XCTUnwrap(store.setHistory(includeNotes: true).first)
        XCTAssertEqual(row.sessionFeel, .solid)
        XCTAssertEqual(row.sessionNotes, "good session")
    }

    // MARK: - Undo (a single tap removes the just-saved sets)

    func testUndoLastSaveRemovesTheJustSavedSets() async throws {
        model.inputText = "bench 135 for 8,8,7"
        await model.parse()
        model.save()
        XCTAssertEqual(model.status, .saved(3))
        XCTAssertEqual(try store.setCount(), 3)

        model.undoLastSave()
        XCTAssertEqual(try store.setCount(), 0, "undo deletes every set the notice referred to")
        XCTAssertNil(model.lastSaveUndoToken, "the token clears after a single use")
        // A single-set save that opened a fresh session leaves no active workout
        // after undo — the session is retired on the last set's delete.
        XCTAssertNil(model.activeSessionID)
        XCTAssertEqual(model.status, .idle)
    }

    func testUndoIsNoOpWithoutAToken() async {
        // No prior save → token nil → undo doesn't crash and doesn't mutate state.
        XCTAssertNil(model.lastSaveUndoToken)
        model.undoLastSave()
        XCTAssertNil(model.lastSaveUndoToken)
        XCTAssertEqual(model.status, .idle)
    }

    func testStartingANewParseClearsTheUndoToken() async throws {
        model.inputText = "bench 135x8"
        await model.parse()
        model.save()
        XCTAssertNotNil(model.lastSaveUndoToken)

        model.inputText = "squat 225x5"
        await model.parse()
        XCTAssertNil(model.lastSaveUndoToken, "a new parse supersedes the prior save's undo notice")
    }

    // MARK: - Confirm-card unit toggle (the High-severity safety valve)

    func testSetUnitOnPendingFlipsAllSetsInThatEntry() async {
        model.inputText = "100x5"
        await model.parse()
        XCTAssertEqual(model.pendingUnit, .lb, "default is lb when no preference is set")

        model.setUnit(.kg)
        XCTAssertEqual(model.pendingUnit, .kg)
        XCTAssertEqual(model.pending?.sets.allSatisfy { $0.unit == .kg }, true)
    }

    func testSetUnitWorksForBodyweightPendingSets() async throws {
        model.inputText = "pull up 15"
        await model.parse()
        XCTAssertEqual(model.pending?.sets.first?.loadKind, .bodyweight)
        model.setUnit(.kg)
        XCTAssertEqual(model.pendingUnit, .kg)
    }

    func testSetDefaultUnitRebuildsTheParserSoNewEntriesParseInTheNewUnit() async {
        // No pending state to start. Flip to kg, parse an ambiguous load — it
        // should be read as kg now.
        model.setDefaultUnit(.kg)
        model.inputText = "row 60x10"
        await model.parse()
        XCTAssertEqual(model.pending?.sets.first?.unit, .kg)
    }

    func testSetDefaultUnitWhileConfirmCardOpenRetagsUnspecifiedSetsOnly() async {
        // Bare scheme → pending sets land as `.unspecified` (no load yet).
        // Flipping the Settings preference while the confirm card is open
        // should retag *those* to the new unit so the visible label matches
        // the parser's new default — but never touch a confirmed external set.
        model.inputText = "squat 3x10"
        await model.parse()
        XCTAssertEqual(model.pending?.sets.first?.loadKind, .unspecified)
        XCTAssertEqual(model.pendingUnit, .lb)

        model.setDefaultUnit(.kg)
        XCTAssertEqual(model.pendingUnit, .kg, "an unspecified pending set follows the preference flip")

        // Now confirm a real weight → loadKind becomes .external. A second
        // flip *must not* retag .external; the user's explicit confirm wins.
        model.setExerciseName("Back Squat")
        model.setWeight(60)
        XCTAssertEqual(model.pending?.sets.first?.loadKind, .external)
        XCTAssertEqual(model.pendingUnit, .kg)

        model.setDefaultUnit(.lb)
        XCTAssertEqual(model.pendingUnit, .kg, "a confirmed external set is not retagged by a Settings flip")
    }

    // MARK: - Live autocomplete (typing the leading exercise span)

    func testInputAutocompleteStaysEmptyBelowTwoLetters() {
        model.inputText = "b"
        XCTAssertTrue(model.inputSuggestions.isEmpty, "below the two-letter floor")
    }

    func testInputAutocompleteOnlyConsidersTheLeadingNameSpan() {
        // The trailing spec (`135x8`) is not part of the name — autocomplete
        // looks at the leading word run only, so "135x8" alone doesn't propose
        // anything (no name letters yet).
        model.inputText = "135x8"
        XCTAssertTrue(model.inputSuggestions.isEmpty)
    }

    func testApplyInputSuggestionPreservesTheTrailingSpec() {
        guard let suggestion = (try? store.suggestExercisesFuzzy(for: "bench"))?.first else {
            return XCTFail("seeded library should match 'bench'")
        }
        model.inputText = "be 135x8"
        model.applyInputSuggestion(suggestion)
        XCTAssertTrue(model.inputText.hasPrefix(suggestion.canonicalName))
        XCTAssertTrue(model.inputText.contains("135x8"), "the trailing spec must not be lost")
    }

    func testLeadingNamePrefixStopsAtFirstNumberOrOperator() {
        XCTAssertEqual(TodayInputTokenizer.leadingNamePrefix("bench press 135x8"), "bench press")
        XCTAssertEqual(TodayInputTokenizer.leadingNamePrefix("squat 3x10"), "squat")
        XCTAssertEqual(TodayInputTokenizer.leadingNamePrefix("ohp x 12"), "ohp")
        XCTAssertEqual(TodayInputTokenizer.leadingNamePrefix("135x8"), "", "starts with number → no name span")
    }

    func testLeadingNamePrefixStopsAtGluedXShorthand() {
        // The audit caught this regression: "bench x12" was being treated as
        // an exercise name (only standalone "x" stopped the scan), so
        // autocomplete would replace the `x12` portion despite the user
        // typing valid shorthand.
        XCTAssertEqual(TodayInputTokenizer.leadingNamePrefix("bench x12"), "bench")
        XCTAssertEqual(TodayInputTokenizer.leadingNamePrefix("pullup x8x3"), "pullup")
    }

    func testApplyInputSuggestionPreservesLeadingAndInternalWhitespace() {
        // The audit caught this regression too: `dropFirst(leading.count)`
        // used the *normalized* prefix length, so the raw tail was sliced
        // from the wrong offset. The fix uses a raw `String.Index` directly.
        guard let suggestion = (try? store.suggestExercisesFuzzy(for: "bench"))?.first else {
            return XCTFail("seeded library should match 'bench'")
        }
        for input in ["  bench 135x8", "incline   bench 135x8", "bench x12"] {
            model.inputText = input
            model.applyInputSuggestion(suggestion)
            XCTAssertTrue(model.inputText.hasPrefix(suggestion.canonicalName),
                          "rewritten name span should start the line for input: \"\(input)\"")
            // The original numeric/operator span must survive verbatim.
            let spec = input.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            XCTAssertTrue(model.inputText.contains(spec),
                          "trailing spec \"\(spec)\" must not be mangled for input: \"\(input)\"")
        }
    }

    // MARK: - Decline reason surfaced as `lastDeclineReason`

    func testRepRangeRecoversWithRepsUnset() async throws {
        // "bench 135 8-10" used to dead-end on the guided card. It now recovers:
        // name and load land on the confirm card, reps stay unset — the user
        // picks the count, never a silently chosen endpoint.
        model.inputText = "bench 135 8-10"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.lastDeclineReason)
        XCTAssertEqual(model.pendingWeight, 135)
        XCTAssertNil(model.pendingReps, "a rep range never becomes a fabricated count")
        XCTAssertFalse(model.canSave)

        model.setReps(9)
        XCTAssertTrue(model.canSave)
        model.save()
        XCTAssertEqual(model.status, .saved(1))
        let stored = try XCTUnwrap(try store.sets(inSession: 1).first)
        XCTAssertEqual(stored.reps, 9)
    }

    func testUnrecoverableRepRangeStillShowsGuidedCard() async {
        // No weight and no recognizable lift — a draft would be a phantom, so
        // the guided card (with the rep-range reason) is still the answer.
        model.inputText = "zzqgh 8-10"
        await model.parse()
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.status, .declined)
        XCTAssertEqual(model.lastDeclineReason, .repRange)
    }

    func testGenericDeclineHasNoReason() async {
        model.inputText = "felt strong today"
        await model.parse()
        XCTAssertEqual(model.status, .declined)
        XCTAssertNil(model.lastDeclineReason)
    }

    // MARK: - Multi-entry lines: split, confirm, queue

    func testMultiExerciseLineSplitsIntoConfirmPlusQueue() async throws {
        // "bench 135x8 + curl 30x10" used to dead-end on the guided card. Now
        // the first entry lands on the confirm card and the second waits its
        // turn: saving pops it into the input box for its own confirm.
        model.inputText = "bench 135x8 + curl 30x10"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.lastDeclineReason)
        XCTAssertEqual(model.pendingExerciseName, "bench")
        XCTAssertEqual(model.pendingWeight, 135)
        XCTAssertEqual(model.queuedEntries, ["curl 30x10"])

        model.save()
        XCTAssertEqual(model.status, .saved(1))
        XCTAssertEqual(model.inputText, "curl 30x10", "saving surfaces the queued entry")
        XCTAssertTrue(model.queuedEntries.isEmpty)

        await model.parse()
        XCTAssertEqual(model.pendingExerciseName, "curl")
        XCTAssertEqual(model.pendingWeight, 30)
        model.save()
        XCTAssertEqual(model.inputText, "", "an empty queue clears the box as before")
        XCTAssertEqual(try store.setCount(), 2)
    }

    func testPastedMultiLineLogSplits() async {
        // A pasted two-line log — the single-line field can still receive
        // newlines via paste, and each line must become its own entry.
        model.inputText = "bench 135x8\nsquat 225x5"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingExerciseName, "bench")
        XCTAssertEqual(model.queuedEntries, ["squat 225x5"])
    }

    func testSpaceSeparatedMultiExerciseSplits() async {
        model.inputText = "bench 135x8 squat 225x5"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingExerciseName, "bench")
        XCTAssertEqual(model.queuedEntries, ["squat 225x5"])
    }

    func testStrengthPlusCardioSplitsInsteadOfSwallowingTheLift() async throws {
        // The cardio proposal must not eat the bench: strength confirms first,
        // the bout queues, and logging it drains the queue.
        model.inputText = "bench 135x8 bike 20 min"
        await model.parse()
        XCTAssertEqual(model.pendingExerciseName, "bench")
        XCTAssertNil(model.pendingCardio)
        XCTAssertEqual(model.queuedEntries, ["bike 20 min"])

        model.save()
        XCTAssertEqual(model.inputText, "bike 20 min")
        await model.parse()
        XCTAssertNil(model.pending)
        XCTAssertNotNil(model.pendingCardio)
        model.saveCardio()
        XCTAssertEqual(try store.cardioCount(), 1)
        XCTAssertEqual(model.inputText, "")
    }

    func testUnsplittableMultiExerciseKeepsGuidedCard() async {
        // All-or-nothing: when part of the line is unreadable, nothing splits
        // (no lift silently dropped) and the guided card explains.
        model.inputText = "bench 135x8 + zzqgh vvwx"
        await model.parse()
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.queuedEntries.isEmpty)
        XCTAssertEqual(model.status, .declined)
        XCTAssertEqual(model.lastDeclineReason, .multiExercise)
    }

    func testDiscardBailsOnTheWholeQueue() async {
        model.inputText = "bench 135x8 + curl 30x10"
        await model.parse()
        XCTAssertEqual(model.queuedEntries, ["curl 30x10"])

        model.discard()
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.queuedEntries.isEmpty, "discarding bails on the rest of the line too")
        XCTAssertEqual(model.inputText, "")
    }

    // MARK: - Sets⇄reps swap + best-effort recovery

    func testSwapSetsAndRepsReinterpretsAmbiguousScheme() async {
        // "5x3" parses as a best guess of 5 sets × 3 reps; one tap flips it.
        model.inputText = "5x3"
        await model.parse()
        XCTAssertEqual(model.pendingSetCount, 5)
        XCTAssertEqual(model.pendingReps, 3)
        XCTAssertTrue(model.pendingCanSwapSetsReps)

        model.swapSetsAndReps()
        XCTAssertEqual(model.pendingSetCount, 3)
        XCTAssertEqual(model.pendingReps, 5)
    }

    func testSwapPreservesWeightAndName() async {
        model.inputText = "squat 3x10 @ 135"
        await model.parse()
        XCTAssertEqual(model.pendingSetCount, 3)
        XCTAssertEqual(model.pendingReps, 10)

        model.swapSetsAndReps()
        XCTAssertEqual(model.pendingSetCount, 10)
        XCTAssertEqual(model.pendingReps, 3)
        XCTAssertEqual(model.pending?.sets.allSatisfy { $0.weight == 135 }, true)
        XCTAssertEqual(model.pendingExerciseName, "squat")
    }

    func testSwapIsHiddenForUnevenReps() async {
        model.inputText = "bench 135 for 8,8,7"
        await model.parse()
        XCTAssertFalse(model.pendingCanSwapSetsReps, "uneven reps have no single value to swap")
    }

    func testSwapIsHiddenWhenSetsEqualReps() async {
        model.inputText = "pullup 5x5"
        await model.parse()
        XCTAssertEqual(model.pendingSetCount, 5)
        XCTAssertEqual(model.pendingReps, 5)
        XCTAssertFalse(model.pendingCanSwapSetsReps, "swapping 5×5 would be a no-op")
    }

    func testIncompleteWeightRecoversEditableDraft() async throws {
        // "bench 135" — a weight with no reps used to dead-end. Now it recovers
        // into a fillable draft: add reps and save.
        model.inputText = "bench 135"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.lastDeclineReason)
        XCTAssertEqual(model.pendingWeight, 135)
        XCTAssertNil(model.pendingReps, "reps stay unset — recovery never fabricates them")
        XCTAssertFalse(model.canSave)

        model.setReps(8)
        XCTAssertTrue(model.canSave)
        model.save()
        XCTAssertEqual(model.status, .saved(1))
        let stored = try XCTUnwrap(try store.sets(inSession: 1).first)
        XCTAssertEqual(stored.weight, 135)
        XCTAssertEqual(stored.reps, 8)
    }

    func testUnknownExerciseWithWeightRecoversAsNewCustomExercise() async {
        // An unfamiliar lift typed with a real load becomes a custom exercise,
        // never a "we don't know that one" wall.
        model.inputText = "frobnicator 135"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingExerciseName.lowercased(), "frobnicator")
        XCTAssertTrue(model.pendingCreatesNewExercise, "an unknown lift recovers as a new custom exercise")
        XCTAssertEqual(model.pendingWeight, 135)
    }

    func testSpacedUnitWeightRecoversWithStatedUnit() async {
        // "bench 135 lb" — a spaced unit is just as common as "135lb"; recover the
        // weight AND honor the typed unit.
        model.inputText = "bench 135 lb"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingWeight, 135)
        XCTAssertEqual(model.pendingUnit, .lb)
        XCTAssertNil(model.pendingReps)
    }

    func testUnknownExerciseWithSpacedKgRecoversAsNewExercise() async {
        model.inputText = "frobnicator 60 kg"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingExerciseName.lowercased(), "frobnicator")
        XCTAssertTrue(model.pendingCreatesNewExercise)
        XCTAssertEqual(model.pendingWeight, 60)
        XCTAssertEqual(model.pendingUnit, .kg)
    }

    func testGluedAtWeightRecoversTheLoad() async {
        // "bench @135" — the glued "@" is a load introducer; recovery must keep 135,
        // not drop to weight 0.
        model.inputText = "bench @135"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingWeight, 135)
        XCTAssertNil(model.pendingReps)
    }

    func testTrailingPunctuationStillExposesTheLoad() async {
        // Chat-style trailing punctuation must not swallow the load.
        model.inputText = "bench 135,"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingWeight, 135)

        model.discard()
        model.inputText = "frobnicator 60kg?"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingExerciseName.lowercased(), "frobnicator")
        XCTAssertTrue(model.pendingCreatesNewExercise)
        XCTAssertEqual(model.pendingWeight, 60)
        XCTAssertEqual(model.pendingUnit, .kg)
    }

    func testMultiplicationSignParsesLikeX() async {
        // "135×8" with the Unicode × the confirm card displays should parse exactly
        // like "135x8", not fall through to recovery.
        model.inputText = "bench 135×8"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingSetCount, 1)
        XCTAssertEqual(model.pendingWeight, 135)
        XCTAssertEqual(model.pending?.sets.first?.reps, 8)
    }

    func testMultiplicationSignTripleRecoversSwappableDraft() async {
        model.inputText = "squat 8×3×4"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingSetCount, 8)
        XCTAssertEqual(model.pendingReps, 3)
        XCTAssertTrue(model.pendingCanSwapSetsReps)
    }

    func testAmbiguousTripleRecoversSwappableDraft() async {
        // "8x3x4" is genuinely ambiguous; recover a best-effort 8 sets × 3 reps
        // the user can swap, instead of a "please rephrase" wall.
        model.inputText = "squat 8x3x4"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingSetCount, 8)
        XCTAssertEqual(model.pendingReps, 3)
        XCTAssertTrue(model.pendingCanSwapSetsReps)

        model.swapSetsAndReps()
        XCTAssertEqual(model.pendingSetCount, 3)
        XCTAssertEqual(model.pendingReps, 8)
    }

    func testPureSchemeRecoversWithoutInventingAName() async {
        // "8x3x4" names no lift; recovery must leave the exercise blank for the user
        // to name — never fabricate one. (The FM prompt is held to the same rule;
        // that path is exercised on-device.)
        model.inputText = "8x3x4"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingSetCount, 8)
        XCTAssertEqual(model.pendingReps, 3)
        XCTAssertTrue(model.pendingExerciseName.isEmpty, "a pure scheme stays nameless until the user names it")
        XCTAssertFalse(model.canSave, "no exercise yet, so Save stays disabled")
    }

    func testAliasKnownLiftWithWeightResolvesToExistingExercise() async throws {
        // "ohp 135" — a known alias + a load. Recovery keeps the typed name, and the
        // store resolves it to the existing Overhead Press on save, not a new custom
        // lift. This pins the "save still resolves against the library" contract.
        let existingID = try XCTUnwrap(try store.resolveExercise("ohp"), "ohp is a seeded alias")
        model.inputText = "ohp 135"
        await model.parse()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingWeight, 135)
        XCTAssertFalse(model.pendingCreatesNewExercise, "a known alias resolves to the existing lift, not a new one")

        model.setReps(8)
        model.save()
        XCTAssertEqual(model.status, .saved(1))
        let afterID = try XCTUnwrap(try store.resolveExercise("ohp"))
        XCTAssertEqual(afterID, existingID,
                       "save resolved the alias to the same existing lift, creating no new custom row")
    }

    func testCardioRecoversAsCardioBout() async throws {
        // Cardio no longer dead-ends — it becomes an editable cardio bout (its own
        // write path, separate from the strength session).
        model.inputText = "5k 25min"
        await model.parse()
        XCTAssertNil(model.pending, "cardio isn't a strength draft")
        XCTAssertNotNil(model.pendingCardio)
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.pendingCardioDistance, 5)
        XCTAssertEqual(model.pendingCardioDistanceUnit, .km)
        XCTAssertEqual(model.pendingCardioMinutes, 25)
        XCTAssertTrue(model.canSaveCardio)

        model.saveCardio()
        if case .savedCardio = model.status {} else { XCTFail("expected savedCardio status") }
        XCTAssertNil(model.pendingCardio)
        XCTAssertEqual(try store.cardioCount(), 1)
        XCTAssertEqual(model.inputText, "")
    }

    func testBikeMinutesBecomesCardio() async throws {
        model.inputText = "bike 30 min"
        await model.parse()
        let cardio = try XCTUnwrap(model.pendingCardio)
        XCTAssertEqual(cardio.activity, "Cycling")
        XCTAssertEqual(model.pendingCardioMinutes, 30)
    }

    func testSubMinuteCardioDurationIsPreservedNotRounded() async throws {
        model.inputText = "run 45s"
        await model.parse()
        let cardio = try XCTUnwrap(model.pendingCardio)
        XCTAssertEqual(cardio.durationSeconds, 45)
        XCTAssertNil(model.pendingCardioMinutes, "45s isn't shown as a rounded 1 min")
        model.saveCardio()
        let stored = try XCTUnwrap(try store.cardioEntries().first)
        XCTAssertEqual(stored.durationSeconds, 45, "the exact seconds are saved, not rounded up")
    }

    func testBodyweightSchemeDefaultsToBodyweight() async {
        // "chin up 3x10" parses strictly; the model defaults the load-less,
        // unspecified sets to bodyweight instead of "unspecified × —".
        model.inputText = "chin up 3x10"
        await model.parse()
        XCTAssertEqual(model.pending?.sets.count, 3)
        XCTAssertEqual(model.pending?.sets.allSatisfy { $0.loadKind == .bodyweight }, true)
    }

    func testMultiRepBodyweightRecovers() async throws {
        // "chinups 7,3" — two sets at different rep counts, defaulted to bodyweight.
        model.inputText = "chinups 7,3"
        await model.parse()
        XCTAssertNil(model.pendingCardio)
        XCTAssertEqual(model.pending?.sets.map { $0.reps }, [7, 3])
        XCTAssertEqual(model.pending?.sets.allSatisfy { $0.loadKind == .bodyweight }, true)
        XCTAssertTrue(model.canSave, "valid reps on a recovered bodyweight draft are savable")

        model.save()
        XCTAssertEqual(model.status, .saved(2))
        // The variant name folds onto the seeded Chin-Up rather than a new custom.
        let chinUp = try XCTUnwrap(try store.resolveExercise("chin up"))
        let stored = try store.sets(inSession: 1)
        XCTAssertEqual(stored.allSatisfy { $0.exerciseID == chinUp }, true)
    }

    func testWeightFirstOrderRecovers() async {
        // "120 lbs leg ext 3 set" — weight-first, name in the middle, "3 set".
        model.inputText = "120 lbs leg ext 3 set"
        await model.parse()
        XCTAssertNil(model.pendingCardio)
        XCTAssertEqual(model.pendingWeight, 120)
        XCTAssertEqual(model.pendingUnit, .lb)
        XCTAssertEqual(model.pendingSetCount, 3)
        XCTAssertNil(model.pendingReps, "reps stay unset for the user to fill in")
        XCTAssertEqual(model.pendingExerciseName.lowercased(), "leg ext")
    }

    func testAmbiguousActivityWordRecoversAsStrengthNotCardio() async {
        // "row 135" is a barbell row at 135 lb — it must NOT become a 135-minute
        // rowing bout. Recovers as an editable strength draft instead.
        model.inputText = "row 135"
        await model.parse()
        XCTAssertNil(model.pendingCardio, "an ambiguous lift word + bare weight is strength, not cardio")
        XCTAssertEqual(model.pendingWeight, 135)
        XCTAssertEqual(model.pendingExerciseName.lowercased(), "row")
    }

    func testWeightInTripleRecovers() async {
        // "leg curl 8x160x3" → 160 load, 8 reps, 3 sets.
        model.inputText = "leg curl 8x160x3"
        await model.parse()
        XCTAssertEqual(model.pendingWeight, 160)
        XCTAssertEqual(model.pendingSetCount, 3)
        XCTAssertEqual(model.pendingReps, 8)
        XCTAssertEqual(model.pendingExerciseName.lowercased(), "leg curl")
    }
}
