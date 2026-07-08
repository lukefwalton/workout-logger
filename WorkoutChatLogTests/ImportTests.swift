import XCTest
@testable import WorkoutChatLog

@MainActor
final class ImportTests: XCTestCase {

    private var paths: [String] = []

    override func tearDownWithError() throws {
        for path in paths {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        paths = []
    }

    private func makeStore(_ tag: String) throws -> WorkoutStore {
        let path = NSTemporaryDirectory() + "wcl-import-\(tag)-\(UUID().uuidString).sqlite"
        paths.append(path)
        let store = WorkoutStore(db: try SQLiteDB(path: path))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
        return store
    }

    private func makeSet(_ name: String, _ weight: Double, _ reps: Int, kind: WorkoutLoadKind = .external) -> SetDraft {
        SetDraft(exerciseName: name, weight: weight, unit: .lb, loadKind: kind, reps: reps, rir: nil, setType: .working, notes: nil)
    }

    private func signature(_ rows: [WorkoutSetHistoryRow]) -> [String] {
        rows.map {
            "\($0.exerciseName)|\($0.load.displayText)|\($0.reps)|\($0.setType.rawValue)|"
            + "\($0.sessionName ?? "")|\($0.sessionFeel?.rawValue ?? "")|\($0.sessionIsDeload)"
        }
    }

    func testJSONRoundTripReproducesSessionsSetsExercises() throws {
        let source = try makeStore("src")
        let push = try source.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0), name: "Push", notes: "good",
            sets: [makeSet("Bench Press", 135, 8), makeSet("Pull-Up", 0, 10, kind: .bodyweight)]))
        try source.finishSession(push.sessionID, name: nil, notes: nil, feel: .solid, isDeload: false)
        _ = try source.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 86_400), name: nil, notes: nil,
            sets: [makeSet("Jefferson Curl", 95, 8)]))   // a custom lift

        let export = try source.dataExport(includeNotes: true)

        let fresh = try makeStore("dst")
        let summary = try fresh.importData(export)
        XCTAssertEqual(summary.addedSessions, 2)
        XCTAssertEqual(summary.addedSets, 3)
        XCTAssertEqual(summary.addedExercises, 1, "only the custom lift is created; seeded lifts match by slug")

        XCTAssertEqual(try fresh.sessionCount(), 2)
        XCTAssertEqual(try fresh.setCount(), 3)
        XCTAssertEqual(signature(try source.setHistory(includeNotes: true)),
                       signature(try fresh.setHistory(includeNotes: true)),
                       "round-trip reproduces every set by content")
    }

    func testReimportIsIdempotent() throws {
        let source = try makeStore("src2")
        _ = try source.save(WorkoutDraft(startedAt: Date(timeIntervalSince1970: 0), name: nil, notes: nil,
            sets: [makeSet("Bench Press", 135, 8)]))
        let export = try source.dataExport()

        let fresh = try makeStore("dst2")
        XCTAssertEqual(try fresh.importData(export).addedSessions, 1)
        let second = try fresh.importData(export)
        XCTAssertEqual(second.addedSessions, 0, "re-importing the same file adds nothing")
        XCTAssertEqual(second.skippedSessions, 1)
        XCTAssertEqual(try fresh.sessionCount(), 1, "no duplicate session")
    }

    func testDryRunPreviewsWithoutWriting() throws {
        let source = try makeStore("src3")
        _ = try source.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
            sets: [makeSet("Bench Press", 135, 8), makeSet("Jefferson Curl", 95, 8)]))
        let export = try source.dataExport()

        let fresh = try makeStore("dst3")
        let preview = try fresh.importData(export, dryRun: true)
        XCTAssertEqual(preview.addedSessions, 1)
        XCTAssertEqual(preview.addedExercises, 1)
        XCTAssertEqual(try fresh.sessionCount(), 0, "a dry-run writes nothing")
        XCTAssertEqual(try fresh.exerciseCount(), 94, "…not even the custom exercise")
    }

    func testMalformedFileFailsCleanly() throws {
        XCTAssertThrowsError(try WorkoutStore.decodeExport(Data("definitely not json".utf8)))
    }

    // MARK: - Cardio (schema_version 3)

    private func makeCardio(_ activity: String, seconds: Int? = nil, distance: Double? = nil,
                            unit: CardioDistanceUnit? = nil, notes: String? = nil,
                            sourceText: String? = nil, at: Date) -> CardioDraft {
        var draft = CardioDraft(activity: activity, durationSeconds: seconds, distance: distance,
                                distanceUnit: unit, notes: notes, sourceText: sourceText)
        draft.loggedAt = at
        return draft
    }

    private func cardioSignature(_ entries: [CardioEntry]) -> [String] {
        entries.map {
            let duration = $0.durationSeconds.map { String($0) } ?? "-"
            let distance = $0.distance.map { String($0) } ?? "-"
            return "\($0.activity)|\(duration)|\(distance)|"
                + "\($0.distanceUnit?.rawValue ?? "-")|\($0.notes ?? "-")|\($0.sourceText ?? "-")|\(WorkoutDateFormat.string($0.loggedAt))"
        }
    }

    func testCardioRoundTripReproducesBouts() throws {
        let source = try makeStore("csrc")
        try source.saveCardio(makeCardio("Run", seconds: 1800, distance: 3.1, unit: .mi,
                                         notes: "tempo", sourceText: "ran 5k",
                                         at: Date(timeIntervalSince1970: 0)))
        try source.saveCardio(makeCardio("Cycling", seconds: 2400, distance: 15, unit: .km,
                                         at: Date(timeIntervalSince1970: 86_400)))

        let fresh = try makeStore("cdst")
        let summary = try fresh.importData(try source.dataExport(includeNotes: true))
        XCTAssertEqual(summary.addedCardio, 2)
        XCTAssertEqual(summary.skippedCardio, 0)
        XCTAssertEqual(cardioSignature(try source.cardioEntries()),
                       cardioSignature(try fresh.cardioEntries()),
                       "round-trip reproduces every bout by content, mixed units verbatim")
    }

    func testCardioReimportIsIdempotent() throws {
        let source = try makeStore("csrc2")
        try source.saveCardio(makeCardio("Run", seconds: 1800, at: Date(timeIntervalSince1970: 0)))
        try source.saveCardio(makeCardio("Walk", distance: 2, unit: .km, at: Date(timeIntervalSince1970: 3600)))
        let export = try source.dataExport()

        let fresh = try makeStore("cdst2")
        XCTAssertEqual(try fresh.importData(export).addedCardio, 2)
        let second = try fresh.importData(export)
        XCTAssertEqual(second.addedCardio, 0, "re-importing the same file adds no bouts")
        XCTAssertEqual(second.skippedCardio, 2)
        XCTAssertEqual(try fresh.cardioCount(), 2)
    }

    func testIdenticalBoutsInOneFileBothImport() throws {
        // Two genuinely identical bouts (same second, same metrics) are two facts.
        // The count-based fingerprint must land both on a fresh import — a plain
        // EXISTS check would collapse them — while a re-import still adds none.
        let source = try makeStore("csrc3")
        let when = Date(timeIntervalSince1970: 500)
        try source.saveCardio(makeCardio("Run", seconds: 600, at: when))
        try source.saveCardio(makeCardio("Run", seconds: 600, at: when))
        let export = try source.dataExport()

        let fresh = try makeStore("cdst3")
        XCTAssertEqual(try fresh.importData(export).addedCardio, 2, "both identical bouts import")
        XCTAssertEqual(try fresh.cardioCount(), 2)
        let second = try fresh.importData(export)
        XCTAssertEqual(second.addedCardio, 0)
        XCTAssertEqual(second.skippedCardio, 2)
        XCTAssertEqual(try fresh.cardioCount(), 2)
    }

    func testCardioDedupIgnoresNotesAndSourceText() throws {
        // Deliberate: notes and source_text are NOT part of the bout's identity,
        // so a notes-excluded export stays idempotent against a store whose same
        // bouts carry notes (and vice versa). Same time + activity + metrics =
        // same bout, regardless of prose.
        let source = try makeStore("csrc6")
        let when = Date(timeIntervalSince1970: 700)
        try source.saveCardio(makeCardio("Run", seconds: 1800, notes: "with notes",
                                         sourceText: "ran 30", at: when))
        let notesExcluded = try source.dataExport(includeNotes: false)

        let dest = try makeStore("cdst6")
        try dest.saveCardio(makeCardio("Run", seconds: 1800, notes: "different words entirely",
                                       sourceText: "jogged half an hour", at: when))
        let summary = try dest.importData(notesExcluded)
        XCTAssertEqual(summary.addedCardio, 0, "same time + activity + metrics is the same bout")
        XCTAssertEqual(summary.skippedCardio, 1)
        XCTAssertEqual(try dest.cardioCount(), 1)
    }

    func testDryRunPreviewsCardioWithoutWriting() throws {
        let source = try makeStore("csrc4")
        try source.saveCardio(makeCardio("Run", seconds: 1800, at: Date()))
        let export = try source.dataExport()

        let fresh = try makeStore("cdst4")
        let preview = try fresh.importData(export, dryRun: true)
        XCTAssertEqual(preview.addedCardio, 1)
        XCTAssertEqual(try fresh.cardioCount(), 0, "a dry-run writes no cardio")
    }

    func testV2FileWithoutCardioStillImports() throws {
        // A pre-cardio export (no top-level "cardio" key) must keep importing —
        // the wire contract tolerates absence.
        let json = """
        {"schema_version":2,"exported_at":"2026-06-21T00:00:00Z","app":"WorkoutChatLog",
         "analytics_policy":{"hard_set_rir_threshold":4,"count_null_rir_as_hard":true,
                             "working_equivalent_set_types":["working"]},
         "exercises":[{"id":1,"slug":"bench_press","canonical_name":"Bench Press","family_key":null,
                       "primary_muscle":"chest","secondary_muscles":[],"is_custom":false,
                       "aliases":[],"created_at":"2026-01-01T00:00:00Z"}],
         "sessions":[{"id":1,"started_at":"2026-06-01T10:00:00Z","ended_at":"2026-06-01T10:30:00Z",
                      "name":null,"notes":null,"feel":null,"is_deload":false,
                      "created_at":"2026-06-01T10:00:00Z",
                      "sets":[{"id":1,"exercise_id":1,"exercise_name":"Bench Press","set_index":1,
                               "set_type":"working","load":{"kind":"external","amount":135,"unit":"lb"},
                               "reps":8,"rir":null,"notes":null,"source_text":null,
                               "created_at":"2026-06-01T10:00:00Z"}]}]}
        """
        let fresh = try makeStore("cdst5")
        let summary = try fresh.importData(try WorkoutStore.decodeExport(Data(json.utf8)))
        XCTAssertEqual(summary.addedSessions, 1)
        XCTAssertEqual(summary.addedCardio, 0)
        XCTAssertEqual(summary.skippedCardio, 0)
    }
}
