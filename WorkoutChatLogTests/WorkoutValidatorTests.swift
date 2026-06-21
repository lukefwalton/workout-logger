import XCTest
@testable import WorkoutChatLog

final class WorkoutValidatorTests: XCTestCase {

    private func draft(_ sets: [SetDraft]) -> WorkoutDraft {
        WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: sets)
    }

    private func makeSet(name: String = "Bench Press", weight: Double = 135, reps: Int = 8, rir: Int? = nil) -> SetDraft {
        SetDraft(exerciseName: name, weight: weight, unit: .lb,
                 reps: reps, rir: rir, setType: .working, notes: nil, sourceText: nil)
    }

    func testValidDraftPasses() {
        XCTAssertNoThrow(try WorkoutValidator.validate(draft([makeSet()])))
    }

    func testEmptyDraftThrowsNoSets() {
        assertThrows(.noSets) { try WorkoutValidator.validate(draft([])) }
    }

    func testBlankExerciseNameThrows() {
        assertThrows(.emptyExerciseName) { try WorkoutValidator.validate(draft([makeSet(name: "")])) }
        assertThrows(.emptyExerciseName) { try WorkoutValidator.validate(draft([makeSet(name: "   ")])) }
    }

    func testNegativeWeightThrows() {
        assertThrows(.badWeight) { try WorkoutValidator.validate(draft([makeSet(weight: -1)])) }
    }

    func testBodyweightZeroIsAllowed() {
        XCTAssertNoThrow(try WorkoutValidator.validate(draft([makeSet(weight: 0)])))
    }

    func testNonFiniteWeightThrows() {
        assertThrows(.badWeight) { try WorkoutValidator.validate(draft([makeSet(weight: .infinity)])) }
        assertThrows(.badWeight) { try WorkoutValidator.validate(draft([makeSet(weight: .nan)])) }
    }

    func testRepBounds() {
        assertThrows(.badReps) { try WorkoutValidator.validate(draft([makeSet(reps: 0)])) }
        assertThrows(.badReps) { try WorkoutValidator.validate(draft([makeSet(reps: 101)])) }
        XCTAssertNoThrow(try WorkoutValidator.validate(draft([makeSet(reps: 1)])))
        XCTAssertNoThrow(try WorkoutValidator.validate(draft([makeSet(reps: 100)])))
    }

    func testRIRBounds() {
        assertThrows(.badRIR) { try WorkoutValidator.validate(draft([makeSet(rir: -1)])) }
        assertThrows(.badRIR) { try WorkoutValidator.validate(draft([makeSet(rir: 11)])) }
        XCTAssertNoThrow(try WorkoutValidator.validate(draft([makeSet(rir: 0)])))
        XCTAssertNoThrow(try WorkoutValidator.validate(draft([makeSet(rir: 10)])))
    }

    func testValidationStopsTheWholeDraft() {
        // A single bad set rejects the entire draft — no partial acceptance.
        assertThrows(.badReps) {
            try WorkoutValidator.validate(draft([makeSet(), makeSet(reps: 999)]))
        }
    }

    private func assertThrows(_ expected: ParseError,
                              _ body: () throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? ParseError, expected, file: file, line: line)
        }
    }
}
