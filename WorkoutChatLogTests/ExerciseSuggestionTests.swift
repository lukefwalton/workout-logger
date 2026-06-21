import XCTest
@testable import WorkoutChatLog

@MainActor
final class ExerciseSuggestionTests: XCTestCase {

    private var dbPath: String!
    private var store: WorkoutStore!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "wcl-suggest-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: dbPath))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    // MARK: - FuzzyMatch (pure)

    func testJaroWinklerBasics() {
        XCTAssertEqual(FuzzyMatch.jaroWinkler("bench", "bench"), 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(FuzzyMatch.jaroWinkler("bnch", "bench"), 0.8)
        XCTAssertLessThan(FuzzyMatch.jaroWinkler("asdf", "bench"), 0.6)
    }

    func testSimilarityIsGenerousForTyposAndTokens() {
        XCTAssertGreaterThan(FuzzyMatch.similarity("bnch press", "Bench Press"), 0.9)
        XCTAssertGreaterThan(FuzzyMatch.similarity("dops", "dip"), 0.72)   // ~0.75 — the spec's worked example
        XCTAssertLessThan(FuzzyMatch.similarity("asdfqwer", "Bench Press"), 0.6)
    }

    // MARK: - Store suggestions (resolution Layer 2)

    func testDopsSurfacesDipVariants() throws {
        let suggestions = try store.suggestExercisesFuzzy(for: "dops")
        let names = Set(suggestions.map(\.canonicalName))
        XCTAssertTrue(names.contains("Chest Dip") || names.contains("Triceps Dip"), "dops surfaces dip variants")
        XCTAssertTrue(suggestions.contains { $0.familyKey == "dip" })
        XCTAssertTrue(suggestions.allSatisfy { $0.via == .fuzzy })
    }

    func testTypoRanksTheClosestCanonicalFirst() throws {
        let suggestions = try store.suggestExercisesFuzzy(for: "bnch press")
        XCTAssertEqual(suggestions.first?.canonicalName, "Bench Press", "closest-length match ranks first, not Incline")
    }

    func testBareAmbiguousTermReturnsMultipleFamilyMembers() throws {
        // "dip" is no lift's alias by design, so it falls through to the suggester
        // and the user chooses among dip canonicals — never auto-picked.
        XCTAssertNil(try store.resolveExercise("dip"), "bare 'dip' is not an alias of anything")
        let dips = try store.suggestExercisesFuzzy(for: "dip", limit: 5).filter { $0.familyKey == "dip" }
        XCTAssertGreaterThanOrEqual(dips.count, 2, "multiple dip canonicals are offered")
    }

    func testGarbageReturnsNoSuggestions() throws {
        XCTAssertTrue(try store.suggestExercisesFuzzy(for: "asdfqwer").isEmpty)
        XCTAssertTrue(try store.suggestExercisesFuzzy(for: "qwertyuiop").isEmpty)
    }

    func testAliasedLiftResolvesDirectlyAndIsNeverReassociated() throws {
        // "rdl" hits its owned alias, so resolution never reaches the suggester —
        // it can never be "corrected" onto Deadlift (different muscles).
        let rdl = try XCTUnwrap(store.resolveExercise("rdl"))
        XCTAssertEqual(try store.exercise(id: rdl)?.canonicalName, "Romanian Deadlift")
    }
}
