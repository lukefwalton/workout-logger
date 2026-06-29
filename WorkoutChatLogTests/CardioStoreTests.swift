import XCTest
@testable import WorkoutChatLog

@MainActor
final class CardioStoreTests: XCTestCase {

    private var dbPath: String!
    private var store: WorkoutStore!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "wcl-cardio-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: dbPath))
        try store.migrate()
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
    }

    private func seed() throws {
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
    }

    // MARK: - Schema v3

    func testMigrationIsAtCardioVersion() throws {
        XCTAssertEqual(try store.schemaVersion(), Schema.latestVersion)
        XCTAssertGreaterThanOrEqual(Schema.latestVersion, 3)
        XCTAssertEqual(try store.cardioCount(), 0)
    }

    // MARK: - The one cardio write path

    func testSaveAndReadRoundTrip() throws {
        let draft = CardioDraft(activity: "Run", durationSeconds: 1800,
                                distance: 5, distanceUnit: .km, notes: "easy", sourceText: "ran 5k 30min")
        try store.saveCardio(draft)
        let entries = try store.cardioEntries()
        XCTAssertEqual(entries.count, 1)
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.activity, "Run")
        XCTAssertEqual(e.durationSeconds, 1800)
        XCTAssertEqual(e.distance, 5)
        XCTAssertEqual(e.distanceUnit, .km)
        XCTAssertEqual(e.notes, "easy")
        XCTAssertEqual(e.sourceText, "ran 5k 30min")
    }

    func testNormalizationCoercesRatherThanRejects() throws {
        // Blank activity → "Cardio"; non-positive metrics drop to nil. Cardio
        // never fails to ingest.
        let draft = CardioDraft(activity: "   ", durationSeconds: 0,
                                distance: -3, distanceUnit: .mi, notes: "  ", sourceText: nil)
        try store.saveCardio(draft)
        let e = try XCTUnwrap(try store.cardioEntries().first)
        XCTAssertEqual(e.activity, "Cardio")
        XCTAssertNil(e.durationSeconds)
        XCTAssertNil(e.distance)
        XCTAssertNil(e.distanceUnit)
        XCTAssertNil(e.notes)
    }

    func testDistanceOnlyBoutKeepsUnit() throws {
        try store.saveCardio(CardioDraft(activity: "Swimming", durationSeconds: nil,
                                         distance: 1000, distanceUnit: .m, notes: nil, sourceText: nil))
        let e = try XCTUnwrap(try store.cardioEntries().first)
        XCTAssertNil(e.durationSeconds)
        XCTAssertEqual(e.distance, 1000)
        XCTAssertEqual(e.distanceUnit, .m)
    }

    func testDelete() throws {
        let id = try store.saveCardio(CardioDraft(activity: "Bike", durationSeconds: 600,
                                                  distance: nil, distanceUnit: nil, notes: nil, sourceText: nil))
        XCTAssertEqual(try store.cardioCount(), 1)
        try store.deleteCardioEntry(id)
        XCTAssertEqual(try store.cardioCount(), 0)
    }

    // MARK: - Loose-key exercise joining (spacing / punctuation / plural)

    func testSpacingAndPluralVariantsJoinExistingCanonical() throws {
        try seed()
        let chinUp = try XCTUnwrap(try store.resolveExercise("chin up"))
        // "chin ups" (space + plural) is NOT a seeded alias, yet must fold onto the
        // existing Chin-Up rather than spawn a duplicate custom (the picker bug).
        XCTAssertEqual(try store.resolveExercise("chin ups"), chinUp)
        XCTAssertEqual(try store.resolveExercise("Chin Ups"), chinUp)
        XCTAssertEqual(try store.resolveExercise("chinups"), chinUp)   // seeded alias path

        let pushUp = try XCTUnwrap(try store.resolveExercise("push up"))
        XCTAssertEqual(try store.resolveExercise("push ups"), pushUp)
    }

    func testLooseJoinDoesNotMergeDistinctLifts() throws {
        try seed()
        let bench = try store.resolveExercise("bench press")
        let incline = try store.resolveExercise("incline bench press")
        XCTAssertNotNil(bench)
        XCTAssertNotNil(incline)
        XCTAssertNotEqual(bench, incline, "distinct canonicals must never collapse under loose matching")
        XCTAssertNil(try store.resolveExercise("asdfqwer"), "garbage still resolves to nothing")
    }

    func testSavingAVariantDoesNotCreateADuplicate() throws {
        try seed()
        let before = try store.exerciseCount()
        let draft = WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            SetDraft(exerciseName: "chin ups", weight: 0, unit: .lb, loadKind: .bodyweight, reps: 8)
        ])
        try store.save(draft)
        XCTAssertEqual(try store.exerciseCount(), before, "a spacing/plural variant joins the canonical, no new row")
    }

    func testLooseKeyFolding() {
        XCTAssertEqual(WorkoutStore.looseKey("Chin-Up"), WorkoutStore.looseKey("chin ups"))
        XCTAssertEqual(WorkoutStore.looseKey("Push-Up"), WorkoutStore.looseKey("push ups"))
        XCTAssertNotEqual(WorkoutStore.looseKey("abs"), "ab", "short words aren't over-singularized")
    }
}
