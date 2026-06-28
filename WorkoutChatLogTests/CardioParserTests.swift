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

    func testAmbiguousActivityWordWithBareNumberIsStrength() {
        // "row" doubles as a barbell lift — "row 135" is 135 lb, not a 135-minute
        // row. Without an explicit duration/distance it stays strength.
        XCTAssertNil(parse("row 135"))
        XCTAssertNil(parse("row 135 lb"))
        XCTAssertNil(parse("row 95 x 10"))
    }

    func testWeightUnitForcesStrengthOnlyWithoutAMetric() throws {
        // A barbell unit + no duration/distance ⇒ strength.
        XCTAssertNil(parse("bench 135 lb"))
        XCTAssertNil(parse("squat 60kg"))
        // …but an explicit metric is decisive: weighted cardio is still cardio.
        let ruck = try XCTUnwrap(parse("walk 5 km with 10 kg pack"))
        XCTAssertEqual(ruck.activity, "Walk")
        XCTAssertEqual(ruck.distance, 5)
        XCTAssertEqual(ruck.distanceUnit, .km)
    }

    func testCountBasedInputsLogActivityWithoutFabricatingMetrics() throws {
        // "10k steps" is not 10 km; "20 laps" is not 20 minutes. Recognize the
        // activity but store no fabricated distance/duration.
        let steps = try XCTUnwrap(parse("10k steps"))
        XCTAssertEqual(steps.activity, "Walk")
        XCTAssertNil(steps.distance)
        XCTAssertNil(steps.durationSeconds)

        let bigSteps = try XCTUnwrap(parse("5000 steps"))
        XCTAssertEqual(bigSteps.activity, "Walk")
        XCTAssertNil(bigSteps.durationSeconds)

        let laps = try XCTUnwrap(parse("20 laps"))
        XCTAssertEqual(laps.activity, "Swimming")
        XCTAssertNil(laps.distance)
        XCTAssertNil(laps.durationSeconds)
    }

    func testSeconds() throws {
        // The file's own contract lists "45s"; bare-s must read as seconds, not
        // fall through to minute inference.
        XCTAssertEqual(try XCTUnwrap(parse("run 45s")).durationSeconds, 45)
        XCTAssertEqual(try XCTUnwrap(parse("bike 30 sec")).durationSeconds, 30)
        XCTAssertEqual(try XCTUnwrap(parse("row 90s")).durationSeconds, 90)
    }

    func testAmbiguousActivityStillCardioWithExplicitMetric() throws {
        // With a real duration/distance, "row" is unambiguously the cardio kind.
        XCTAssertEqual(try XCTUnwrap(parse("row 20 min")).activity, "Rowing")
        XCTAssertEqual(try XCTUnwrap(parse("rowing 5k")).distanceUnit, .km)
    }

    func testNonWorkoutProseIsNotCardio() {
        XCTAssertNil(parse("did a great workout"))
        XCTAssertNil(parse(""))
    }
}
