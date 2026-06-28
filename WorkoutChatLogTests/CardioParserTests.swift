import XCTest
@testable import WorkoutChatLog

final class CardioParserTests: XCTestCase {

    private func parse(_ s: String) -> CardioDraft? { CardioParser.parse(s) }

    // MARK: - The screenshot case + the common shapes

    func testBikeMinutes() throws {
        let d = try XCTUnwrap(parse("bike 30 min"))
        XCTAssertEqual(d.activity, "Cycling")
        XCTAssertEqual(d.durationSeconds, 1800)
        XCTAssertNil(d.distance)
    }

    func testRanDistanceKm() throws {
        let d = try XCTUnwrap(parse("ran 5k"))
        XCTAssertEqual(d.activity, "Run")
        XCTAssertEqual(d.distance, 5)
        XCTAssertEqual(d.distanceUnit, .km)
        XCTAssertNil(d.durationSeconds)
    }

    func testRowMinutes() throws {
        let d = try XCTUnwrap(parse("row 20 min"))
        XCTAssertEqual(d.activity, "Rowing")
        XCTAssertEqual(d.durationSeconds, 1200)
    }

    func testDistanceAndDurationTogether() throws {
        let d = try XCTUnwrap(parse("5k 25min"))
        XCTAssertEqual(d.distance, 5)
        XCTAssertEqual(d.distanceUnit, .km)
        XCTAssertEqual(d.durationSeconds, 1500)
        XCTAssertEqual(d.activity, "Cardio")   // no activity word → generic, never empty
    }

    func testSwimMeters() throws {
        let d = try XCTUnwrap(parse("swam 1000m"))
        XCTAssertEqual(d.activity, "Swimming")
        XCTAssertEqual(d.distance, 1000)
        XCTAssertEqual(d.distanceUnit, .m)
    }

    func testMiles() throws {
        let d = try XCTUnwrap(parse("ran 3.1 mi in 25 min"))
        XCTAssertEqual(d.activity, "Run")
        XCTAssertEqual(d.distance, 3.1)
        XCTAssertEqual(d.distanceUnit, .mi)
        XCTAssertEqual(d.durationSeconds, 1500)
    }

    func testColonTimeIsTotalDuration() throws {
        let d = try XCTUnwrap(parse("bike 1:30:00"))
        XCTAssertEqual(d.durationSeconds, 5400)   // 1h 30m
        let mmss = try XCTUnwrap(parse("row 25:00"))
        XCTAssertEqual(mmss.durationSeconds, 1500) // 25 min
    }

    func testCompoundDuration() throws {
        let d = try XCTUnwrap(parse("elliptical 1h 20min"))
        XCTAssertEqual(d.activity, "Elliptical")
        XCTAssertEqual(d.durationSeconds, 4800)
    }

    func testBareNumberWithActivityIsMinutes() throws {
        let d = try XCTUnwrap(parse("elliptical 20"))
        XCTAssertEqual(d.activity, "Elliptical")
        XCTAssertEqual(d.durationSeconds, 1200)
    }

    func testActivityOnlyStillLogs() throws {
        let d = try XCTUnwrap(parse("run"))
        XCTAssertEqual(d.activity, "Run")
        XCTAssertNil(d.durationSeconds)
        XCTAssertNil(d.distance)
    }

    func testUnknownActivityKeepsUsersWords() throws {
        let d = try XCTUnwrap(parse("jazzercise 30 min"))
        XCTAssertEqual(d.activity, "Jazzercise")
        XCTAssertEqual(d.durationSeconds, 1800)
    }

    func testSourceTextPreserved() throws {
        let d = try XCTUnwrap(parse("Bike 30 Min"))
        XCTAssertEqual(d.sourceText, "Bike 30 Min")
    }

    // MARK: - Not cardio → nil (hand back to the strength path)

    func testStrengthSetIsNotCardio() {
        XCTAssertNil(parse("bench 135x8"))
        XCTAssertNil(parse("120 lbs leg ext 3 set"))
        XCTAssertNil(parse("leg curl 8x160x3"))
    }

    func testStrengthMoveContainingCardioWordIsNotCardio() {
        // "walking" / "row" appear in lift names; without a duration/distance and
        // with a foreign exercise word present, these stay strength.
        XCTAssertNil(parse("walking lunge 20"))
        XCTAssertNil(parse("ski squat 135"))
    }

    func testNonWorkoutProseIsNotCardio() {
        XCTAssertNil(parse("did a great workout"))
        XCTAssertNil(parse(""))
    }
}
