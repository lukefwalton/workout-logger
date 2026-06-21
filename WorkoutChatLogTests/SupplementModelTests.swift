import XCTest
@testable import WorkoutChatLog

@MainActor
final class SupplementModelTests: XCTestCase {

    private var path: String!
    private var store: WorkoutStore!

    private let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    private var day2: Date { day1.addingTimeInterval(2 * 86_400) }   // safely a different calendar day

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "wcl-supp-model-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: path))
        try store.migrate()
        try store.seedSupplementsIfNeeded()
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func model(on date: Date) -> SupplementModel {
        SupplementModel(store: store, now: { date })
    }

    private func id(_ model: SupplementModel, _ name: String) throws -> Int64 {
        try XCTUnwrap(model.supplements.first { $0.name == name }?.id)
    }

    func testLoadsSeededPresets() {
        let model = model(on: day1)
        XCTAssertEqual(model.supplements.map(\.name), ["Creatine", "Protein"])
        XCTAssertTrue(model.intakeToday.isEmpty)
    }

    func testToggleMarksTakenAndPersistsWithinTheDay() throws {
        let model = model(on: day1)
        let creatine = try id(model, "Creatine")
        model.toggle(creatine)
        XCTAssertTrue(model.isTaken(creatine))

        // A fresh model the same day sees the check (it's in the DB).
        let reloaded = self.model(on: day1)
        XCTAssertTrue(reloaded.isTaken(creatine))

        reloaded.toggle(creatine)
        XCTAssertFalse(reloaded.isTaken(creatine))
    }

    func testTakenResetsOnANewDayButListPersists() throws {
        let today = model(on: day1)
        today.toggle(try id(today, "Creatine"))
        today.addSupplement(named: "Vitamin D")

        let tomorrow = model(on: day2)
        XCTAssertTrue(tomorrow.intakeToday.isEmpty, "checks clear on a new day")
        XCTAssertEqual(tomorrow.supplements.map(\.name), ["Creatine", "Protein", "Vitamin D"],
                       "the configured list persists across days")
    }

    func testRefreshForTodayClearsChecksWhenTheDayRolls() throws {
        let model = model(on: day1)
        let creatine = try id(model, "Creatine")
        model.toggle(creatine)
        XCTAssertTrue(model.isTaken(creatine))

        // Same model instance, but time has moved to the next day.
        let rolled = SupplementModel(store: store, now: { self.day2 })
        rolled.refreshForToday()
        XCTAssertFalse(rolled.isTaken(creatine))
    }

    func testSetGramsForProteinStoresAmountAndMarksTaken() throws {
        let model = model(on: day1)
        let protein = try id(model, "Protein")
        model.setGrams(protein, grams: 42)
        XCTAssertTrue(model.isTaken(protein))
        XCTAssertEqual(model.grams(protein), 42)

        // Clearing grams keeps it taken.
        model.setGrams(protein, grams: nil)
        XCTAssertTrue(model.isTaken(protein))
        XCTAssertNil(model.grams(protein))
    }

    func testAddCustomSupplementAndValidationErrors() throws {
        let model = model(on: day1)
        XCTAssertTrue(model.addSupplement(named: "  Fish Oil  "))
        XCTAssertNil(model.addError)
        XCTAssertEqual(model.supplements.map(\.name), ["Creatine", "Protein", "Fish Oil"])

        XCTAssertFalse(model.addSupplement(named: "fish oil"), "case-insensitive duplicate")
        XCTAssertNotNil(model.addError)

        XCTAssertFalse(model.addSupplement(named: "   "), "blank")
        XCTAssertNotNil(model.addError)
    }

    func testRemoveCustomButNotPreset() throws {
        let model = model(on: day1)
        model.addSupplement(named: "Magnesium")
        let magnesium = try id(model, "Magnesium")
        let creatine = try id(model, "Creatine")

        model.removeSupplement(creatine)
        XCTAssertTrue(model.supplements.contains { $0.id == creatine }, "presets can't be removed")

        model.removeSupplement(magnesium)
        XCTAssertFalse(model.supplements.contains { $0.id == magnesium })
    }
}
