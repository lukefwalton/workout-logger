import XCTest
@testable import WorkoutChatLog

/// Pure plate math (§4) — exact loads, honest nearest-achievable with remainder,
/// kg/lb sets, and the degenerate cases. No store, no UI. Mirrors the Python
/// prototype's fixtures.
final class PlateCalculatorTests: XCTestCase {

    private let lb = PlateCalculator.defaultPlatesLb
    private let kg = PlateCalculator.defaultPlatesKg

    private func loadout(_ target: Double, bar: Double, plates: [Double], unit: WeightUnit = .lb) -> PlateLoadout {
        PlateCalculator.loadout(target: target, bar: bar, plates: plates, unit: unit)!
    }

    // MARK: - Exact loads

    func test135OnA45BarIsOne45PerSide() {
        let result = loadout(135, bar: 45, plates: lb)
        XCTAssertTrue(result.isExact)
        XCTAssertEqual(result.perSide, [45])
        XCTAssertEqual(result.achieved, 135)
        XCTAssertEqual(result.remainder, 0, accuracy: 1e-9)
    }

    func test225IsTwo45sPerSide() {
        let result = loadout(225, bar: 45, plates: lb)
        XCTAssertTrue(result.isExact)
        XCTAssertEqual(result.perSide, [45, 45])
    }

    func testExactWithMixedPlates() {
        // 100 on a 45 bar → 27.5/side → 25 + 2.5.
        let result = loadout(100, bar: 45, plates: lb)
        XCTAssertTrue(result.isExact)
        XCTAssertEqual(result.perSide, [25, 2.5])
    }

    // MARK: - Nearest-achievable (honest about non-exact)

    func testOddTargetReportsNearestAndRemainder() {
        // 47 on a 45 bar → 1/side, below the smallest 2.5 plate → just the bar,
        // 2 lb short. Never silently rounded.
        let result = loadout(47, bar: 45, plates: lb)
        XCTAssertFalse(result.isExact)
        XCTAssertEqual(result.perSide, [])
        XCTAssertEqual(result.achieved, 45)
        XCTAssertEqual(result.remainder, 2, accuracy: 1e-9, "2 lb short, reported not hidden")
    }

    func testPartialLoadKeepsWhatFitsAndReportsTheShortfall() {
        // 50 on a 45 bar → 2.5/side exactly (45 + 5). Verify the boundary just above.
        let result = loadout(52, bar: 45, plates: lb)
        XCTAssertFalse(result.isExact)
        XCTAssertEqual(result.perSide, [2.5], "loads the 2.5; can't make the last 2 lb")
        XCTAssertEqual(result.achieved, 50)
        XCTAssertEqual(result.remainder, 2, accuracy: 1e-9)
    }

    // MARK: - Degenerate

    func testTargetBelowBarIsNotAchievable() {
        let result = loadout(30, bar: 45, plates: lb)
        XCTAssertFalse(result.isExact)
        XCTAssertEqual(result.perSide, [])
        XCTAssertEqual(result.achieved, 45)
        XCTAssertEqual(result.remainder, -15, accuracy: 1e-9, "can't load less than the bar")
    }

    func testTargetEqualsBarIsExactWithNoPlates() {
        let result = loadout(45, bar: 45, plates: lb)
        XCTAssertTrue(result.isExact)
        XCTAssertEqual(result.perSide, [])
    }

    func testEmptyPlateSetYieldsJustTheBar() {
        let result = loadout(135, bar: 45, plates: [])
        XCTAssertFalse(result.isExact)
        XCTAssertEqual(result.perSide, [])
        XCTAssertEqual(result.achieved, 45)
        XCTAssertEqual(result.remainder, 90, accuracy: 1e-9)
    }

    func testNonFiniteOrNegativeBarReturnsNil() {
        XCTAssertNil(PlateCalculator.loadout(target: 135, bar: -45, plates: lb, unit: .lb))
        XCTAssertNil(PlateCalculator.loadout(target: .nan, bar: 45, plates: lb, unit: .lb))
    }

    // MARK: - kg

    func test60kgOnA20kgBar() {
        let result = loadout(60, bar: 20, plates: kg, unit: .kg)
        XCTAssertTrue(result.isExact)
        XCTAssertEqual(result.perSide, [20])
    }

    func testKgOddTargetReportsNearest() {
        // 61 kg on a 20 bar → 20.5/side → 20 (1.25 doesn't fit the last 0.5) → 60, 1 kg short.
        let result = loadout(61, bar: 20, plates: kg, unit: .kg)
        XCTAssertFalse(result.isExact)
        XCTAssertEqual(result.achieved, 60)
        XCTAssertEqual(result.remainder, 1, accuracy: 1e-9)
    }

    func testKg1Point25PlateFormatsExactlyNotRoundedTo1Point3() {
        // 22.5 kg on a 20 kg bar → exactly one 1.25 kg plate per side. The formatter
        // must show "1.25", not a non-existent "1.3" denomination.
        let result = loadout(22.5, bar: 20, plates: kg, unit: .kg)
        XCTAssertTrue(result.isExact)
        XCTAssertEqual(result.perSide, [1.25])
        XCTAssertEqual(PlateCalculator.perSideText(result), "1.25")
    }

    func testFormatRendersStandardDenominationsHonestly() {
        XCTAssertEqual(PlateCalculator.format(45), "45")
        XCTAssertEqual(PlateCalculator.format(2.5), "2.5")
        XCTAssertEqual(PlateCalculator.format(1.25), "1.25")
        XCTAssertEqual(PlateCalculator.format(102.5), "102.5")
    }

    // MARK: - Formatting

    func testPerSideText() {
        XCTAssertEqual(PlateCalculator.perSideText(loadout(115, bar: 45, plates: lb)), "35",
                       "115 → 35/side")
        XCTAssertEqual(PlateCalculator.perSideText(loadout(45, bar: 45, plates: lb)), "just the bar")
        XCTAssertEqual(PlateCalculator.perSideText(loadout(100, bar: 45, plates: lb)), "25 + 2.5")
    }
}
