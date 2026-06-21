import XCTest
@testable import WorkoutChatLog

@MainActor
final class SupplementStoreTests: XCTestCase {

    private var path: String!
    private var store: WorkoutStore!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "wcl-supp-store-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: path))
        try store.migrate()
        try store.seedSupplementsIfNeeded()
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func id(_ name: String) throws -> Int64 {
        try XCTUnwrap(store.supplements().first { $0.name == name }?.id)
    }

    func testFreshStoreIsV2WithSeededPresets() throws {
        XCTAssertEqual(try store.schemaVersion(), 2)
        let supplements = try store.supplements()
        XCTAssertEqual(supplements.map(\.name), ["Creatine", "Protein"])
        XCTAssertTrue(supplements.allSatisfy(\.isPreset))
        XCTAssertEqual(supplements.first { $0.name == "Protein" }?.tracksGrams, true)
        XCTAssertEqual(supplements.first { $0.name == "Creatine" }?.tracksGrams, false)
    }

    func testSeedingIsIdempotent() throws {
        try store.seedSupplementsIfNeeded()
        try store.seedSupplementsIfNeeded()
        XCTAssertEqual(try store.supplements().count, 2)
    }

    func testForwardMigrationFromV1AddsSupplementTables() throws {
        // A v1.2-era database stamped user_version = 1 (has slug) gets the v2 tables.
        let v1Path = NSTemporaryDirectory() + "wcl-v1-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: v1Path + s) } }
        let db = try SQLiteDB(path: v1Path)
        try db.execute("CREATE TABLE exercises (id INTEGER PRIMARY KEY, slug TEXT NOT NULL UNIQUE, canonical_name TEXT NOT NULL, created_at TEXT NOT NULL);")
        try db.setUserVersion(1)

        try Schema.migrate(db)
        XCTAssertEqual(try db.userVersion(), 2, "forward-migrates v1 → v2")

        let migrated = WorkoutStore(db: db)
        try migrated.seedSupplementsIfNeeded()
        XCTAssertEqual(try migrated.supplements().count, 2, "supplement tables exist after the forward migration")
    }

    func testSetIntakeTogglesPresenceAndUpsertsGrams() throws {
        let protein = try id("Protein")
        let day = "2026-05-30"

        try store.setSupplementIntake(supplementID: protein, day: day, taken: true, grams: 30)
        XCTAssertEqual(try store.supplementIntake(onDay: day)[protein]?.grams, 30)

        // Same day again updates grams rather than duplicating.
        try store.setSupplementIntake(supplementID: protein, day: day, taken: true, grams: 45)
        let intake = try store.supplementIntake(onDay: day)
        XCTAssertEqual(intake[protein]?.grams, 45)
        XCTAssertEqual(intake.count, 1)

        // Untaking removes the row.
        try store.setSupplementIntake(supplementID: protein, day: day, taken: false)
        XCTAssertNil(try store.supplementIntake(onDay: day)[protein])
    }

    func testSetIntakeClampsNegativeGramsToZero() throws {
        let protein = try id("Protein")
        try store.setSupplementIntake(supplementID: protein, day: "2026-05-30", taken: true, grams: -5)
        XCTAssertEqual(try store.supplementIntake(onDay: "2026-05-30")[protein]?.grams, 0)
    }

    func testAddCustomRejectsDuplicateAndRemoveSkipsPresets() throws {
        XCTAssertNotNil(try store.addSupplement(named: "Magnesium"))
        XCTAssertNil(try store.addSupplement(named: "magnesium"), "case-insensitive duplicate")
        XCTAssertNil(try store.addSupplement(named: "   "), "blank")
        XCTAssertEqual(try store.supplements().map(\.name), ["Creatine", "Protein", "Magnesium"])

        // Presets can't be removed; customs can.
        try store.removeSupplement(try id("Creatine"))
        XCTAssertTrue(try store.supplements().contains { $0.name == "Creatine" })

        let magnesium = try id("Magnesium")
        try store.removeSupplement(magnesium)
        XCTAssertFalse(try store.supplements().contains { $0.id == magnesium })
    }

    func testRemovingCustomCascadesItsIntake() throws {
        let magnesium = try XCTUnwrap(try store.addSupplement(named: "Magnesium"))
        try store.setSupplementIntake(supplementID: magnesium, day: "2026-05-29", taken: true)
        try store.removeSupplement(magnesium)
        XCTAssertTrue(try store.supplementHistory(sinceDay: "2026-01-01").allSatisfy { $0.supplementID != magnesium },
                      "intake cascades when its supplement is removed")
    }

    func testHistorySinceDayReturnsSortedRows() throws {
        let creatine = try id("Creatine")
        try store.setSupplementIntake(supplementID: creatine, day: "2026-05-28", taken: true)
        try store.setSupplementIntake(supplementID: creatine, day: "2026-05-30", taken: true)
        try store.setSupplementIntake(supplementID: creatine, day: "2026-05-01", taken: true) // before the window

        let history = try store.supplementHistory(sinceDay: "2026-05-27")
        XCTAssertEqual(history.map(\.day), ["2026-05-28", "2026-05-30"], "sorted, windowed")
    }
}
