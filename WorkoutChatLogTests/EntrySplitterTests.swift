import XCTest
@testable import WorkoutChatLog

/// Boundary rules for the multi-entry splitter. The contract cuts both ways:
/// real multi-exercise breaths split cleanly, while rep lists, prose fillers,
/// long names, and cardio bouts stay whole — a false split chops a real entry
/// in half, so the misses are pinned as hard as the hits.
final class EntrySplitterTests: XCTestCase {

    private func split(_ s: String) -> [String] { EntrySplitter.segments(s) }

    // MARK: - Lines that must split

    func testPlusSeparatorSplits() {
        XCTAssertEqual(split("bench 135x8 + curl 30x10"), ["bench 135x8", "curl 30x10"])
    }

    func testCommaBeforeFreshExerciseSplits() {
        XCTAssertEqual(split("bench 135x8, curl 30x10"), ["bench 135x8", "curl 30x10"])
    }

    func testNewlineSplits() {
        XCTAssertEqual(split("bench 135x8\nsquat 225x5"), ["bench 135x8", "squat 225x5"])
    }

    func testSemicolonSplits() {
        XCTAssertEqual(split("deadlift 315x5; pull ups bw x 8"), ["deadlift 315x5", "pull ups bw x 8"])
    }

    func testSpaceSeparatedSpecsSplit() {
        XCTAssertEqual(split("bench 135x8 squat 225x5"), ["bench 135x8", "squat 225x5"])
    }

    func testAtLoadCompletesASpecForSplitting() {
        XCTAssertEqual(split("bench 3x10 @ 135 ohp 95x5"), ["bench 3x10 @ 135", "ohp 95x5"])
    }

    func testThreeEntriesSplit() {
        XCTAssertEqual(split("bench 135x8 + curl 30x10 + pushdowns 50x12"),
                       ["bench 135x8", "curl 30x10", "pushdowns 50x12"])
    }

    func testTrailingConnectorIsTrimmedOffTheSegment() {
        XCTAssertEqual(split("bench 135x8 and curl 30x10"), ["bench 135x8", "curl 30x10"])
    }

    func testStrengthThenCardioSplits() {
        XCTAssertEqual(split("bench 135x8 bike 20 min"), ["bench 135x8", "bike 20 min"])
    }

    // MARK: - Lines that must stay whole

    func testCommaRepListStaysWhole() {
        XCTAssertEqual(split("bench 135 for 8, 8, 7"), ["bench 135 for 8, 8, 7"])
    }

    func testPlusRepListStaysWhole() {
        XCTAssertEqual(split("chinups 7+3"), ["chinups 7+3"])
    }

    func testThenRepListStaysWhole() {
        XCTAssertEqual(split("chin ups 7 then 3"), ["chin ups 7 then 3"])
    }

    func testLongExerciseNameStaysWhole() {
        XCTAssertEqual(split("close grip bench press 135x8"), ["close grip bench press 135x8"])
    }

    func testModifierAfterSpecStaysWhole() {
        XCTAssertEqual(split("bench 135x8 rpe 8"), ["bench 135x8 rpe 8"])
        XCTAssertEqual(split("squat 225x5 warmup"), ["squat 225x5 warmup"])
    }

    func testCardioBoutStaysWhole() {
        XCTAssertEqual(split("run 5k 25 min"), ["run 5k 25 min"])
    }

    func testSetsRepsProseStaysWhole() {
        XCTAssertEqual(split("bench 2 sets of 8 reps at 135"), ["bench 2 sets of 8 reps at 135"])
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertEqual(split("   "), [])
    }
}
