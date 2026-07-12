import XCTest
@testable import WorkoutChatLog

@MainActor
final class WorkoutStoreTests: XCTestCase {

    private var dbPath: String!
    private var store: WorkoutStore!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "wcl-test-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: dbPath))
        try store.migrate()
    }

    override func tearDownWithError() throws {
        store = nil   // close the connection before deleting files
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    private func seed() throws {
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
    }

    private func makeSet(_ name: String, weight: Double = 135, reps: Int = 8,
                         unit: WeightUnit = .lb, loadKind: WorkoutLoadKind = .external, rir: Int? = nil,
                         type: SetType = .working, notes: String? = nil,
                         sourceText: String? = nil) -> SetDraft {
        SetDraft(exerciseName: name, weight: weight, unit: unit,
                 loadKind: loadKind, reps: reps, rir: rir, setType: type, notes: notes, sourceText: sourceText)
    }

    // MARK: - Migration & seeding

    func testMigrationStampsSchemaVersion() throws {
        XCTAssertEqual(try store.schemaVersion(), Schema.latestVersion)
    }

    func testSeedingLoadsTheLibraryOnce() throws {
        try seed()
        XCTAssertEqual(try store.exerciseCount(), 94)
        try seed()  // reseed upserts on slug — idempotent, no duplicate rows
        try seed()
        XCTAssertEqual(try store.exerciseCount(), 94)
    }

    func testEverySeedAliasResolvesToExactlyOneExercise() throws {
        try seed()
        for seedExercise in try ExerciseSeed.load(from: Bundle(for: Self.self)) {
            for alias in seedExercise.aliases {
                XCTAssertNotNil(try store.resolveExercise(alias),
                                "seed alias \"\(alias)\" must resolve to a lift")
            }
        }
    }

    func testSeededExerciseCarriesSlugAndFamily() throws {
        try seed()
        let bench = try XCTUnwrap(store.exercise(id: try XCTUnwrap(store.resolveExercise("Bench Press"))))
        XCTAssertEqual(bench.slug, "bench_press")
        XCTAssertEqual(bench.familyKey, "bench_press")

        let plankID = try XCTUnwrap(store.resolveExercise("Plank"))
        XCTAssertNil(try store.exercise(id: plankID)?.familyKey, "a singleton has no family")
    }

    func testCustomExerciseGetsGeneratedSlug() throws {
        try seed()
        let id = try store.addExercise(named: "Jefferson Curl")
        let created = try XCTUnwrap(store.exercise(id: id))
        XCTAssertEqual(created.slug, "jefferson_curl")
        XCTAssertNil(created.familyKey, "a custom lift has no family until promoted")
    }

    // MARK: - The write path

    func testExerciseNamesReturnsMostUsedFirstWithinLimit() throws {
        try seed()
        // Log Bench Press twice and Back Squat once so usage ordering is observable.
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press"), makeSet("Bench Press"), makeSet("Back Squat")
        ]))

        let names = try store.exerciseNames(limit: 3)
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(names.first, "Bench Press", "the most-logged lift leads the list")
        XCTAssertEqual(Set(names).count, names.count, "no duplicates")

        // The list still surfaces unused seeded lifts when room remains.
        let many = try store.exerciseNames(limit: 500)
        XCTAssertGreaterThan(many.count, 3)
        XCTAssertEqual(many.first, "Bench Press")
    }

    func testSavePersistsSessionAndSetsInOrder() throws {
        try seed()
        let draft = WorkoutDraft(startedAt: Date(), name: "Push day", notes: nil, sets: [
            makeSet("Bench Press", weight: 135, reps: 8, rir: 2),
            makeSet("Overhead Press", weight: 95, reps: 5, type: .warmup)
        ])

        let result = try store.save(draft)

        XCTAssertEqual(result.setIDs.count, 2)
        XCTAssertEqual(try store.sessionCount(), 1)
        XCTAssertEqual(try store.setCount(), 2)

        let rows = try store.sets(inSession: result.sessionID)
        XCTAssertEqual(rows.map(\.setIndex), [1, 2])
        XCTAssertEqual(rows[0].weight, 135)
        XCTAssertEqual(rows[0].reps, 8)
        XCTAssertEqual(rows[0].rir, 2)
        XCTAssertEqual(rows[0].unit, "lb")
        XCTAssertEqual(rows[0].loadKind, "external")
        XCTAssertEqual(rows[0].setType, "working")
        XCTAssertNil(rows[1].rir, "RIR stays null when not stated")
        XCTAssertEqual(rows[1].setType, "warmup")
    }

    // MARK: - PR / achievement detection (§4)

    func testFirstEverLogReportsNoAchievement() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 135, reps: 8)
        ]))
        XCTAssertTrue(result.achievements.isEmpty, "the first time a lift is logged is never a PR")
    }

    func testBeatingPriorEstimatedOneRepMaxReportsAchievement() throws {
        try seed()
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 135, reps: 8)
        ]))
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 145, reps: 8)
        ]))
        let pr = try XCTUnwrap(result.achievements.first, "beating prior history is a PR")
        XCTAssertEqual(pr.kind, .estimatedOneRepMax)
        XCTAssertEqual(pr.exerciseName, "Bench Press", "the canonical, never a family rollup")
    }

    func testWorseSetReportsNoAchievement() throws {
        try seed()
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 135, reps: 8)
        ]))
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 125, reps: 8)
        ]))
        XCTAssertTrue(result.achievements.isEmpty)
    }

    func testBodyweightRepPRReportsAchievement() throws {
        try seed()
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Pull-Up", weight: 0, reps: 8, loadKind: .bodyweight)
        ]))
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Pull-Up", weight: 0, reps: 12, loadKind: .bodyweight)
        ]))
        let pr = try XCTUnwrap(result.achievements.first, "a bodyweight lift gets a rep PR moment")
        XCTAssertEqual(pr.kind, .maxReps)
        XCTAssertEqual(pr.value, 12)
    }

    func testMixedUnitHistoryDoesNotProduceFalsePR() throws {
        try seed()
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 100, reps: 8, unit: .kg)
        ]))
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 150, reps: 8, unit: .lb)   // lighter than 100 kg in reality
        ]))
        XCTAssertTrue(result.achievements.isEmpty,
                      "a lb set is never compared against kg history — no silent conversion")
    }

    func testUnspecifiedHistoryProducesNoAchievement() throws {
        try seed()
        // Two "bench 3x10" entries with no weight ever confirmed → unspecified load.
        // Unspecified means the load was never committed to, so more reps must not PR.
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 0, reps: 10, loadKind: .unspecified)
        ]))
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 0, reps: 12, loadKind: .unspecified)
        ]))
        XCTAssertTrue(result.achievements.isEmpty, "unspecified loads never PR")
    }

    // MARK: - "Last time" (§4)

    func testLastTimeReturnsMostRecentFinishedSessionsSets() throws {
        try seed()
        let benchID = try XCTUnwrap(store.resolveExercise("Bench Press"))
        // A finished session with three bench sets.
        let session = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 135, reps: 8),
            makeSet("Bench Press", weight: 135, reps: 8),
            makeSet("Bench Press", weight: 130, reps: 6)
        ])).sessionID
        try store.finishSession(session, name: nil, notes: nil, feel: nil, isDeload: false)

        let lastTime = try XCTUnwrap(store.lastTime(forExercise: benchID))
        XCTAssertEqual(lastTime.sets.map(\.reps), [8, 8, 6], "in stored order")
        XCTAssertEqual(lastTime.sets.map { $0.load.amount }, [135, 135, 130])
    }

    func testLastTimeIsNilOnFirstLog() throws {
        try seed()
        let benchID = try XCTUnwrap(store.resolveExercise("Bench Press"))
        XCTAssertNil(try store.lastTime(forExercise: benchID), "no prior finished session yet")
    }

    func testLastTimeDoesNotCountTheOpenSession() throws {
        try seed()
        let benchID = try XCTUnwrap(store.resolveExercise("Bench Press"))
        // The only bench history is in the still-open session → not "last time".
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Bench Press", weight: 145, reps: 5)
        ]))
        XCTAssertNotNil(try store.currentOpenSession(), "precondition: a session is open")
        XCTAssertNil(try store.lastTime(forExercise: benchID),
                     "the in-progress session is never the 'last time'")
    }

    func testLastTimeReconstructsBodyweightLoadHonestly() throws {
        try seed()
        let pullUpID = try XCTUnwrap(store.resolveExercise("Pull-Up"))
        let session = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            makeSet("Pull-Up", weight: 0, reps: 10, loadKind: .bodyweight)
        ])).sessionID
        try store.finishSession(session, name: nil, notes: nil, feel: nil, isDeload: false)

        let lastTime = try XCTUnwrap(store.lastTime(forExercise: pullUpID))
        let load = try XCTUnwrap(lastTime.sets.first?.load)
        XCTAssertEqual(load.kind, .bodyweight)
        XCTAssertNil(load.amount, "a bodyweight row stays loadless — never invented as 0")
        XCTAssertNil(load.unit, "no fabricated lb/kg on a loadless set")
        XCTAssertEqual(load.displayText, "BW")
    }

    func testLastTimeSkipsSessionsWithoutThatExercise() throws {
        try seed()
        let benchID = try XCTUnwrap(store.resolveExercise("Bench Press"))
        // Older finished session has bench; a newer finished session does not.
        let older = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 1000),
                                                name: nil, notes: nil, sets: [makeSet("Bench Press", weight: 125, reps: 8)])).sessionID
        try store.finishSession(older, name: nil, notes: nil, feel: nil, isDeload: false)
        let newer = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 2000),
                                                name: nil, notes: nil, sets: [makeSet("Back Squat", weight: 225, reps: 5)])).sessionID
        try store.finishSession(newer, name: nil, notes: nil, feel: nil, isDeload: false)

        let lastTime = try XCTUnwrap(store.lastTime(forExercise: benchID))
        XCTAssertEqual(lastTime.sets.map { $0.load.amount }, [125],
                       "falls back to the most recent finished session that actually has the lift")
    }

    func testInvalidDraftThrowsAndWritesNothing() throws {
        try seed()
        let empty = WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [])
        XCTAssertThrowsError(try store.save(empty)) {
            XCTAssertEqual($0 as? ParseError, .noSets)
        }
        XCTAssertEqual(try store.sessionCount(), 0)
        XCTAssertEqual(try store.setCount(), 0)
    }

    func testSaveRejectsBlankExerciseNameAndWritesNothing() throws {
        try seed()
        let draft = WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [makeSet("   ")])
        XCTAssertThrowsError(try store.save(draft)) {
            XCTAssertEqual($0 as? ParseError, .emptyExerciseName)
        }
        XCTAssertEqual(try store.sessionCount(), 0)
        XCTAssertEqual(try store.setCount(), 0)
        XCTAssertEqual(try store.exerciseCount(), 94, "no junk exercise row created")
    }

    // MARK: - Exercise resolution cascade

    func testLookupRejectsBlankName() throws {
        XCTAssertThrowsError(try store.resolveExercise("   ")) {
            XCTAssertEqual($0 as? ParseError, .emptyExerciseName)
        }
        XCTAssertEqual(try store.exerciseCount(), 0, "lookup never creates a row")
    }

    func testLookupExactCanonicalIsCaseInsensitive() throws {
        try seed()
        let a = try store.resolveExercise("Bench Press")
        let b = try store.resolveExercise("bench press")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(try store.exerciseCount(), 94, "lookup never creates a row")
    }

    func testLookupByAlias() throws {
        try seed()
        let ohp = try XCTUnwrap(store.resolveExercise("ohp"))
        XCTAssertEqual(try store.exercise(id: ohp)?.canonicalName, "Overhead Press")

        let rdl = try XCTUnwrap(store.resolveExercise("rdl"))
        XCTAssertEqual(try store.exercise(id: rdl)?.canonicalName, "Romanian Deadlift")
        XCTAssertEqual(try store.exerciseCount(), 94, "aliases resolve to existing lifts")
    }

    func testResolutionCollapsesWhitespace() throws {
        try seed()
        let tidy = try store.resolveExercise("bench press")
        let messy = try store.resolveExercise("  bench   press ")
        XCTAssertNotNil(tidy)
        XCTAssertEqual(tidy, messy, "internal/edge whitespace collapses to one lift")
        XCTAssertEqual(try store.exerciseCount(), 94, "no near-duplicate created")
    }

    func testCreatingCollapsesWhitespace() throws {
        try seed()
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                        sets: [makeSet("custom   lift")]))
        XCTAssertEqual(try store.exerciseCount(), 95)
        let id = try XCTUnwrap(store.resolveExercise("custom lift"))
        XCTAssertEqual(try store.exercise(id: id)?.canonicalName, "custom lift",
                       "new lifts are stored whitespace-collapsed")
    }

    /// Creating an exercise row only happens through the save transaction (the
    /// single write path), never via a bare resolve.
    func testSavingUnknownExerciseCreatesItMusclelessOnce() throws {
        try seed()
        XCTAssertNil(try store.resolveExercise("Jefferson Curl"), "unknown before save")

        let first = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                sets: [makeSet("Jefferson Curl")]))
        XCTAssertEqual(try store.exerciseCount(), 95)
        let createdID = try XCTUnwrap(store.resolveExercise("jefferson curl"))
        XCTAssertNil(try store.exercise(id: createdID)?.primaryMuscle,
                     "an unknown lift is created muscle-less for the user to correct")
        XCTAssertEqual(try store.sets(inSession: first.sessionID).first?.exerciseID, createdID)

        // Saving it again reuses the row — no duplicate.
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                        sets: [makeSet("Jefferson Curl")]))
        XCTAssertEqual(try store.exerciseCount(), 95, "no duplicate exercise row")
    }

    func testAddExerciseCreatesLocalRegistryEntryAndReusesDuplicates() throws {
        try seed()

        let first = try store.addExercise(named: "  Jefferson   Curl ")

        XCTAssertEqual(try store.exerciseCount(), 95)
        XCTAssertEqual(try store.exercise(id: first)?.canonicalName, "Jefferson Curl")

        let second = try store.addExercise(named: "jefferson curl")
        XCTAssertEqual(second, first)
        XCTAssertEqual(try store.exerciseCount(), 95, "manual add reuses exact existing exercises")
    }

    func testAddExerciseRejectsBlankName() throws {
        try seed()

        XCTAssertThrowsError(try store.addExercise(named: "   ")) {
            XCTAssertEqual($0 as? ParseError, .emptyExerciseName)
        }
        XCTAssertEqual(try store.exerciseCount(), 94)
    }

    // MARK: - Share/export reads

    func testSetHistoryJoinsSessionsExercisesAndSets() throws {
        try seed()
        let startedAt = Date(timeIntervalSince1970: 0)
        _ = try store.save(WorkoutDraft(startedAt: startedAt,
                                        name: "Push day",
                                        notes: "felt strong",
                                        sets: [
                                            makeSet("Bench Press",
                                                    weight: 135,
                                                    reps: 8,
                                                    rir: 2,
                                                    notes: "smooth",
                                                    sourceText: "bench 135x8 rpe 8")
                                        ]))

        let withoutNotes = try store.setHistory(includeNotes: false)
        XCTAssertEqual(withoutNotes.count, 1)
        XCTAssertEqual(withoutNotes[0].startedAt, "1970-01-01T00:00:00Z")
        XCTAssertEqual(withoutNotes[0].sessionName, "Push day")
        XCTAssertNil(withoutNotes[0].sessionNotes)
        XCTAssertEqual(withoutNotes[0].exerciseName, "Bench Press")
        XCTAssertEqual(withoutNotes[0].load, WorkoutLoad(kind: .external, amount: 135, unit: .lb))
        XCTAssertNil(withoutNotes[0].notes)

        let withNotes = try store.setHistory(includeNotes: true)
        XCTAssertEqual(withNotes[0].sessionNotes, "felt strong")
        XCTAssertEqual(withNotes[0].notes, "smooth")
    }

    func testLoadSerializationDistinguishesBodyweightFromUnspecified() throws {
        try seed()
        _ = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0),
                                        name: nil,
                                        notes: nil,
                                        sets: [
                                            makeSet("Pull-Up", weight: 0, reps: 12, loadKind: .bodyweight, sourceText: "pullup bw x12"),
                                            makeSet("Push-Up", weight: 0, reps: 10, loadKind: .unspecified, sourceText: "pushup 3x10")
                                        ]))

        let rows = try store.setHistory()
        XCTAssertEqual(rows[0].load.kind, .bodyweight)
        XCTAssertEqual(rows[0].load.displayText, "BW")
        XCTAssertEqual(rows[1].load.kind, .unspecified)
        XCTAssertEqual(rows[1].load.displayText, "unspecified")
    }

    func testAISharePromptUsesMarkdownTableAndExcludesNotesByDefault() throws {
        try seed()
        _ = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0),
                                        name: nil,
                                        notes: "private session note",
                                        sets: [
                                            makeSet("Bench Press",
                                                    weight: 135,
                                                    reps: 8,
                                                    rir: 2,
                                                    notes: "private set note",
                                                    sourceText: "bench 135x8 rpe 8")
                                        ]))

        let prompt = WorkoutShareSummary.aiPrompt(rows: try store.setHistory(), days: 30)

        XCTAssertTrue(prompt.contains("Here is my recent training log."))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("act as a strength coach"))
        XCTAssertTrue(prompt.contains("| Date | Exercise | Set | Load | Reps | RIR | Type |"))
        XCTAssertTrue(prompt.contains("| 1970-01-01T00:00:00Z | Bench Press | 1 | 135 lb | 8 | 2 | working |"))
        XCTAssertFalse(prompt.contains("private set note"))
        XCTAssertFalse(prompt.contains("private session note"))
        XCTAssertFalse(prompt.contains("{"), "AI share should be markdown, not JSON")
    }

    func testAISharePromptCanIncludeDeterministicTrendSummary() throws {
        try seed()
        let first = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0),
                                        name: nil,
                                        notes: nil,
                                        sets: [
                                            makeSet("Bench Press", weight: 100, reps: 8, rir: 3),
                                            makeSet("Bench Press", weight: 120, reps: 10, rir: 1)
                                        ]))
        // Finish so the second entry opens a distinct session. Without this the
        // single-open invariant adopts the still-open session and both collapse
        // into one workout (the very per-entry-session bug PR 3 fixes).
        try store.finishSession(first.sessionID, name: nil, notes: nil, feel: nil, isDeload: false)
        _ = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 86_400),
                                        name: nil,
                                        notes: nil,
                                        sets: [
                                            makeSet("Bench Press", weight: 140, reps: 6, rir: nil),
                                            makeSet("Bench Press", weight: 160, reps: 8, rir: 2)
                                        ]))

        let prompt = WorkoutShareSummary.aiPrompt(rows: try store.setHistory(),
                                                  days: 30,
                                                  includeTrends: true)

        XCTAssertTrue(prompt.contains("## Deterministic Trend Summary"))
        XCTAssertTrue(prompt.contains("| Exercise | Sets | Sessions | Avg Load | Avg Reps | Avg RIR | Load Trend |"))
        XCTAssertTrue(prompt.contains("| Bench Press | 4 | 2 | 130 lb | 8 | 2 | +40 lb |"))
    }

    func testTrendSummarySurfacesMixedUnitsExplicitly() throws {
        // Two sessions of the same lift, logged in different units → the trend can't be
        // computed honestly (no silent conversion, §1), so the row must say so rather
        // than read "n/a" alongside genuinely-no-data lifts.
        try seed()
        let first = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0),
                                                name: nil, notes: nil,
                                                sets: [
                                                    makeSet("Bench Press", weight: 135, reps: 8, unit: .lb)
                                                ]))
        try store.finishSession(first.sessionID, name: nil, notes: nil, feel: nil, isDeload: false)
        _ = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 86_400),
                                        name: nil, notes: nil,
                                        sets: [
                                            makeSet("Bench Press", weight: 60, reps: 8, unit: .kg)
                                        ]))

        let prompt = WorkoutShareSummary.aiPrompt(rows: try store.setHistory(),
                                                  days: 30,
                                                  includeTrends: true)

        XCTAssertTrue(prompt.contains("(mixed units — trend omitted)"))
    }

    func testFullDataExportIsVersionedJSONShapeAndCanOmitNotes() throws {
        try seed()
        _ = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0),
                                        name: "Push day",
                                        notes: "private session note",
                                        sets: [
                                            makeSet("Bench Press",
                                                    weight: 135,
                                                    reps: 8,
                                                    rir: 2,
                                                    notes: "private set note",
                                                    sourceText: "bench 135x8 rpe 8")
                                        ]))

        let export = try store.dataExport(includeNotes: false, exportedAt: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(export.schemaVersion, 3)
        XCTAssertEqual(export.exportedAt, "1970-01-01T00:00:10Z")
        XCTAssertGreaterThan(export.exercises.count, 0)
        XCTAssertEqual(export.sessions.count, 1)
        XCTAssertNil(export.sessions[0].notes)
        XCTAssertEqual(export.sessions[0].sets.count, 1)
        XCTAssertNil(export.sessions[0].sets[0].notes)
        XCTAssertEqual(export.sessions[0].sets[0].load, WorkoutLoad(kind: .external, amount: 135, unit: .lb))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(export), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"schema_version\":3"))
        XCTAssertTrue(json.contains("\"analytics_policy\""))
        XCTAssertTrue(json.contains("\"load\""))
        XCTAssertTrue(json.contains("\"cardio\""), "the cardio key is always present, even when empty")
    }

    // MARK: - Active session lifecycle (PR 3)

    func testSessionOpensLazilyOnFirstSave() throws {
        try seed()
        XCTAssertNil(try store.currentOpenSession(), "no session row exists until the first set")
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press")]), into: nil)
        let open = try XCTUnwrap(store.currentOpenSession())
        XCTAssertEqual(open.id, result.sessionID)
        XCTAssertEqual(open.setCount, 1)
    }

    func testAppendingContinuesSetIndexInOneSession() throws {
        try seed()
        let first = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                sets: [makeSet("Bench Press"), makeSet("Bench Press")]), into: nil)
        let second = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press")]), into: first.sessionID)
        XCTAssertEqual(second.sessionID, first.sessionID, "the second entry lands in the same session")
        XCTAssertEqual(try store.sessionCount(), 1)
        XCTAssertEqual(try store.sets(inSession: first.sessionID).map(\.setIndex), [1, 2, 3],
                       "set_index continues from MAX+1 — no UNIQUE(session_id, set_index) collision")
    }

    func testStartSessionEnforcesSingleOpen() throws {
        _ = try store.startSession()
        XCTAssertThrowsError(try store.startSession()) {
            XCTAssertEqual($0 as? WorkoutStoreError, .openSessionExists)
        }
    }

    func testFinishClosesSessionAndNextSaveOpensNew() throws {
        try seed()
        let first = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                sets: [makeSet("Bench Press")]), into: nil)
        try store.finishSession(first.sessionID, name: nil, notes: nil, feel: nil, isDeload: false)
        XCTAssertNil(try store.currentOpenSession(), "finishing closes the session")
        let second = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press")]), into: nil)
        XCTAssertNotEqual(second.sessionID, first.sessionID, "the next entry opens a fresh session")
        XCTAssertEqual(try store.sessionCount(), 2)
    }

    // MARK: - reconcileOpenSession (the OCR / bypass-writer stale-session guard)

    func testReconcileRetiresAStaleOpenSession() throws {
        // A session opened "today" is stale once `now` is a different local day. The OCR
        // importer runs this before save(into: nil) so scanned sets can't merge into a
        // session left open overnight.
        try seed()
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                        sets: [makeSet("Bench Press")]), into: nil)
        XCTAssertNotNil(try store.currentOpenSession(), "precondition: a session is open")

        try store.reconcileOpenSession(now: Date().addingTimeInterval(2 * 24 * 60 * 60))
        XCTAssertNil(try store.currentOpenSession(), "a cross-day open session must be retired")
    }

    func testReconcileKeepsAFreshOpenSession() throws {
        try seed()
        let saved = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                sets: [makeSet("Bench Press")]), into: nil)
        try store.reconcileOpenSession(now: Date())   // same day, within the gap → adopt
        XCTAssertEqual(try store.currentOpenSession()?.id, saved.sessionID,
                       "a same-day session must stay open")
    }

    func testReconcileThenSaveOpensAFreshSession() throws {
        // End-to-end OCR guarantee: once a stale session is retired, the next
        // save(into: nil) opens a NEW session rather than adopting the retired one.
        try seed()
        let stale = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                sets: [makeSet("Bench Press")]), into: nil)
        try store.reconcileOpenSession(now: Date().addingTimeInterval(2 * 24 * 60 * 60))
        let fresh = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                sets: [makeSet("Squat")]), into: nil)
        XCTAssertNotEqual(fresh.sessionID, stale.sessionID,
                          "new sets must land in a fresh session, not the retired one")
    }

    func testFinishOnEmptySessionDeletesIt() throws {
        let id = try store.startSession()
        try store.finishSession(id, name: nil, notes: nil, feel: nil, isDeload: false)
        XCTAssertEqual(try store.sessionCount(), 0, "a session with no sets is removed, never left empty")
    }

    func testBackdatedSessionStartsInThePast() throws {
        let past = Date(timeIntervalSince1970: 0)
        let id = try store.startSession(name: "Yesterday", startedAt: past)
        let open = try XCTUnwrap(store.currentOpenSession())
        XCTAssertEqual(open.id, id)
        XCTAssertEqual(open.startedAt.timeIntervalSince1970, 0, accuracy: 1, "backdated start persists")
    }

    func testFinishMetadataRoundTripsThroughHistory() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press")]), into: nil)
        try store.finishSession(result.sessionID, endedAt: Date(timeIntervalSince1970: 3600),
                                name: "Push day", notes: "solid session", feel: .off, isDeload: true)
        let row = try XCTUnwrap(store.setHistory(includeNotes: true).first)
        XCTAssertEqual(row.sessionFeel, .off)
        XCTAssertTrue(row.sessionIsDeload)
        XCTAssertEqual(row.sessionName, "Push day")
        XCTAssertEqual(row.sessionNotes, "solid session")
        XCTAssertNotNil(row.sessionEndedAt, "ended_at round-trips to history")
    }

    func testTwoBareSavesStayInOneOpenSession() throws {
        try seed()
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [makeSet("Bench Press")]))
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [makeSet("Overhead Press")]))
        XCTAssertEqual(try store.sessionCount(), 1, "save(_:) adopts the open session — one workout, not two open rows")
        XCTAssertEqual(try store.setCount(), 2)
    }

    func testSaveIntoStaleClosedSessionDoesNotReopenIt() throws {
        try seed()
        let first = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [makeSet("Bench Press")]))
        try store.finishSession(first.sessionID, name: nil, notes: nil, feel: nil, isDeload: false)
        // Passing the now-closed id must not append to it; a fresh session opens.
        let second = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press")]), into: first.sessionID)
        XCTAssertNotEqual(second.sessionID, first.sessionID)
        XCTAssertEqual(try store.setCount(inSession: first.sessionID), 1, "the closed session is untouched")
    }

    func testFinishWithoutNotesPreservesOpenTimeNotes() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: "felt strong",
                                                 sets: [makeSet("Bench Press")]))
        try store.finishSession(result.sessionID, name: nil, notes: nil, feel: .solid, isDeload: false)
        let row = try XCTUnwrap(store.setHistory(includeNotes: true).first)
        XCTAssertEqual(row.sessionNotes, "felt strong", "a blank finish keeps notes captured at open")
        XCTAssertEqual(row.sessionFeel, .solid)
    }

    func testFinishWithNotesOverwritesOpenTimeNotes() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: "felt strong",
                                                 sets: [makeSet("Bench Press")]))
        try store.finishSession(result.sessionID, name: nil, notes: "actually rough", feel: nil, isDeload: false)
        let row = try XCTUnwrap(store.setHistory(includeNotes: true).first)
        XCTAssertEqual(row.sessionNotes, "actually rough")
    }

    // MARK: - History edits (PR 4)

    func testDeleteSetLeavesAMultiSetSession() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press"), makeSet("Bench Press")]))
        try store.deleteSet(result.setIDs[0])
        XCTAssertEqual(try store.sessionCount(), 1, "the session survives while it still has sets")
        XCTAssertEqual(try store.setCount(), 1)
    }

    func testDeleteLastSetRemovesItsSession() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [makeSet("Bench Press")]))
        try store.deleteSet(result.setIDs[0])
        XCTAssertEqual(try store.setCount(), 0)
        XCTAssertEqual(try store.sessionCount(), 0, "deleting the last set removes the now-empty session")
    }

    func testDeleteSetsBatchIsTransactionalAndPrunesEmptySessions() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press"),
                                                        makeSet("Bench Press"),
                                                        makeSet("Bench Press")]))
        try store.deleteSets(result.setIDs)
        XCTAssertEqual(try store.setCount(), 0)
        XCTAssertEqual(try store.sessionCount(), 0,
                       "every set deleted ⇒ the now-empty session is pruned in the same transaction")
    }

    func testDeleteSetsRollsBackOnAnInvalidID() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press"), makeSet("Bench Press")]))
        // A non-existent id deletes 0 rows but doesn't throw — sqlite's DELETE
        // is happy. The transactional contract still holds; the surviving rows
        // are exactly what we asked to delete.
        try store.deleteSets([result.setIDs[0], 999_999_999])
        XCTAssertEqual(try store.setCount(), 1, "only the real id was deleted; the bogus id was a no-op")
    }

    func testDeleteSessionRemovesItAndCascadesSets() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press"), makeSet("Overhead Press")]))
        try store.deleteSession(result.sessionID)
        XCTAssertEqual(try store.sessionCount(), 0)
        XCTAssertEqual(try store.setCount(), 0, "sets cascade with the session")
    }

    func testUpdateSetPersistsAndRevalidates() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press", weight: 135, reps: 8)]))
        let setID = result.setIDs[0]
        try store.updateSet(setID, exerciseName: "Bench Press", weight: 145, unit: .lb,
                            loadKind: .external, reps: 6, rir: 1, setType: .working, notes: "tweak")
        let stored = try XCTUnwrap(store.sets(inSession: result.sessionID).first)
        XCTAssertEqual(stored.weight, 145)
        XCTAssertEqual(stored.reps, 6)
        XCTAssertEqual(stored.rir, 1)
        XCTAssertEqual(stored.notes, "tweak")

        XCTAssertThrowsError(try store.updateSet(setID, exerciseName: "Bench Press", weight: 145, unit: .lb,
                                                 loadKind: .external, reps: 0, rir: nil, setType: .working, notes: nil)) {
            XCTAssertEqual($0 as? ParseError, .badReps)
        }
        XCTAssertEqual(try store.sets(inSession: result.sessionID).first?.reps, 6, "a rejected edit changes nothing")
    }

    func testUpdateSetReResolvesChangedExerciseName() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [makeSet("Bench Press")]))
        let before = try store.exerciseCount()
        try store.updateSet(result.setIDs[0], exerciseName: "Jefferson Curl", weight: 95, unit: .lb,
                            loadKind: .external, reps: 8, rir: nil, setType: .working, notes: nil)
        let newID = try XCTUnwrap(store.resolveExercise("Jefferson Curl"))
        XCTAssertEqual(try store.sets(inSession: result.sessionID).first?.exerciseID, newID,
                       "the set re-points to the re-resolved exercise")
        XCTAssertEqual(try store.exerciseCount(), before + 1, "the unknown name created exactly one custom exercise")
    }

    func testUpdateSessionSetsTimesAndRejectsEndBeforeStart() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0), name: nil, notes: nil,
                                                 sets: [makeSet("Bench Press")]))
        let start = Date(timeIntervalSince1970: 1000)
        try store.updateSession(result.sessionID, name: "Backfilled", startedAt: start,
                                endedAt: start.addingTimeInterval(3600), notes: "post-filled",
                                feel: .neutral, isDeload: true)
        let row = try XCTUnwrap(store.setHistory(includeNotes: true).first)
        XCTAssertEqual(row.sessionName, "Backfilled")
        XCTAssertEqual(row.sessionNotes, "post-filled")
        XCTAssertEqual(row.sessionFeel, .neutral)
        XCTAssertTrue(row.sessionIsDeload)
        XCTAssertNotNil(row.sessionEndedAt)

        XCTAssertThrowsError(try store.updateSession(result.sessionID, name: nil, startedAt: start,
                                                     endedAt: start.addingTimeInterval(-100), notes: nil,
                                                     feel: nil, isDeload: false)) {
            XCTAssertEqual($0 as? WorkoutStoreError, .endBeforeStart)
        }
    }

    func testEditingBodyweightSetStaysBodyweight() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
            sets: [makeSet("Pull-Up", weight: 0, reps: 10, loadKind: .bodyweight)]))
        try store.updateSet(result.setIDs[0], exerciseName: "Pull-Up", weight: 0, unit: .lb,
                            loadKind: .bodyweight, reps: 12, rir: nil, setType: .working, notes: nil)
        let row = try XCTUnwrap(store.setHistory().first)
        XCTAssertEqual(row.load.kind, .bodyweight)
        XCTAssertEqual(row.load.displayText, "BW", "an edited bodyweight set stays BW, not 0 lb")
        XCTAssertEqual(row.reps, 12)
    }

    func testUpdateSessionWithNilEndKeepsAnOpenSessionOpen() throws {
        try seed()
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [makeSet("Bench Press")]))
        // The session is open (ended_at NULL). Editing metadata with no end time
        // must not close it (the History session editor passes nil when "Finished"
        // is off).
        try store.updateSession(result.sessionID, name: "Renamed", startedAt: nil, endedAt: nil,
                                notes: nil, feel: .solid, isDeload: false)
        XCTAssertEqual(try store.currentOpenSession()?.id, result.sessionID, "still in progress")
        let row = try XCTUnwrap(store.setHistory(includeNotes: true).first)
        XCTAssertEqual(row.sessionName, "Renamed")
        XCTAssertNil(row.sessionEndedAt)
    }

    // MARK: - Snapshot consistency (store altitude)

    /// The `snapshot` contract proven at the store's own altitude, mirroring
    /// the connection-level hammer in SQLiteDBTests: while the main actor
    /// saves two-set drafts, a background reader inside one `store.snapshot`
    /// must never observe half a save — neither an odd set count nor two
    /// reads of the same table that disagree with each other.
    func testSnapshotNeverObservesHalfASave() throws {
        try seed()
        let store = try XCTUnwrap(self.store)
        let group = DispatchGroup()
        var inconsistencies = 0
        let lock = NSLock()

        DispatchQueue(label: "snapshot-reader").async(group: group) {
            for _ in 0..<200 {
                let observed = (try? store.snapshot { () throws -> (Int, Int) in
                    (try store.setCount(), try store.setCount())
                }) ?? (0, 0)
                if observed.0 % 2 != 0 || observed.0 != observed.1 {
                    lock.lock(); inconsistencies += 1; lock.unlock()
                }
            }
        }

        for _ in 0..<40 {
            try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
                makeSet("Bench Press"), makeSet("Squat")
            ]))
        }

        group.wait()
        XCTAssertEqual(inconsistencies, 0,
                       "a snapshot observed a torn save (odd set count, or two reads disagreeing)")
        XCTAssertEqual(try store.setCount(), 80, "every save must have committed cleanly")
    }

    // Transaction rollback and FK-cascade behavior are exercised directly
    // against SQLiteDB + Schema in SQLiteDBTests, at the connection's own
    // altitude. (Feature code still can't casually reach WorkoutStore.db —
    // the file split made it internal, and scripts/check_store_boundary.sh
    // polices the boundary in CI.)
}
