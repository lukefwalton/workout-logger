import XCTest
@testable import WorkoutChatLog

@MainActor
final class DeterministicParserTests: XCTestCase {

    func testFixtures() {
        for fixture in parserFixtures {
            let parsed = DeterministicParser.parse(fixture.input)

            guard let expected = fixture.expected else {
                XCTAssertNil(parsed, "expected the parser to decline: \"\(fixture.input)\"")
                continue
            }
            guard let parsed else {
                XCTFail("expected a parse for: \"\(fixture.input)\"")
                continue
            }

            XCTAssertEqual(parsed.count, expected.count, "set count for: \"\(fixture.input)\"")
            for (got, want) in zip(parsed, expected) {
                XCTAssertEqual(got.exerciseName, fixture.exercise, "name for: \"\(fixture.input)\"")
                XCTAssertEqual(got.weight, want.weight, "weight for: \"\(fixture.input)\"")
                XCTAssertEqual(got.unit, want.unit, "unit for: \"\(fixture.input)\"")
                XCTAssertEqual(got.loadKind, want.loadKind, "loadKind for: \"\(fixture.input)\"")
                XCTAssertEqual(got.reps, want.reps, "reps for: \"\(fixture.input)\"")
                XCTAssertEqual(got.rir, want.rir, "rir for: \"\(fixture.input)\"")
                XCTAssertEqual(got.setType, want.setType, "setType for: \"\(fixture.input)\"")
                XCTAssertEqual(got.sourceText, fixture.input, "sourceText for: \"\(fixture.input)\"")
            }
        }
    }

    func testFixtureSuiteIsSubstantialAndMixed() {
        XCTAssertGreaterThanOrEqual(parserFixtures.count, 45)
        XCTAssertTrue(parserFixtures.contains { $0.expected == nil }, "needs declined cases")
        XCTAssertTrue(parserFixtures.contains { $0.expected != nil }, "needs recognized cases")
    }

    // MARK: - The interesting decisions, documented as tests

    func testWeightVsSetCountDisambiguation() {
        // Large leading number → weight × reps (one set).
        let heavy = DeterministicParser.parse("bench 135x8")
        XCTAssertEqual(heavy?.count, 1)
        XCTAssertEqual(heavy?.first?.weight, 135)

        // Small leading number → set count, weight unspecified.
        let scheme = DeterministicParser.parse("bench 3x10")
        XCTAssertEqual(scheme?.count, 3)
        XCTAssertEqual(scheme?.first?.weight, 0)
        XCTAssertEqual(scheme?.first?.reps, 10)

        // Small leading number WITH a unit → weight, not a set count —
        // whether the unit is glued ("10lb x 12") or separated ("10 kg x 12").
        for input in ["curl 10lb x 12", "curl 10 kg x 12"] {
            let lightDB = DeterministicParser.parse(input)
            XCTAssertEqual(lightDB?.count, 1, "\(input)")
            XCTAssertEqual(lightDB?.first?.weight, 10, "\(input)")
            XCTAssertEqual(lightDB?.first?.reps, 12, "\(input)")
        }
    }

    func testCaseAndSpacingDoNotChangeCompactWeightRepParse() {
        let compact = DeterministicParser.parse("bench 135x8")
        let spaced = DeterministicParser.parse("bench 135 x 8")
        let upper = DeterministicParser.parse("bench 135X8")

        XCTAssertEqual(compact?.map(\.weight), spaced?.map(\.weight))
        XCTAssertEqual(compact?.map(\.reps), spaced?.map(\.reps))
        XCTAssertEqual(compact?.map(\.weight), upper?.map(\.weight))
        XCTAssertEqual(compact?.map(\.reps), upper?.map(\.reps))
    }

    func testRPEConvertsToRIRAndRIRStaysNilUnlessStated() {
        XCTAssertEqual(DeterministicParser.parse("bench 225x5 rpe 8")?.first?.rir, 2)
        XCTAssertEqual(DeterministicParser.parse("bench 225x5 rir 3")?.first?.rir, 3)
        XCTAssertNil(DeterministicParser.parse("bench 225x5")?.first?.rir)
    }

    func testDeclinesMalformedOrOutOfRangeEffort() {
        // Decimal or out-of-range effort declines (defers to Track 2) rather than
        // being silently rounded/clamped into a different persisted RIR.
        XCTAssertNil(DeterministicParser.parse("bench 225x5 rpe 7.5"))
        XCTAssertNil(DeterministicParser.parse("bench 225x5 rir 2.5"))
        XCTAssertNil(DeterministicParser.parse("bench 225x5 rpe 12"))
        XCTAssertNil(DeterministicParser.parse("bench 225x5 rpe 0"))
        XCTAssertNil(DeterministicParser.parse("bench 225x5 rir 11"))
        XCTAssertNil(DeterministicParser.parse("bench 225x5 rir -1"))
        // Boundaries remain valid.
        XCTAssertEqual(DeterministicParser.parse("bench 225x5 rpe 10")?.first?.rir, 0)
        XCTAssertEqual(DeterministicParser.parse("bench 225x5 rpe 1")?.first?.rir, 9)
    }

    func testDeclinesRepsAboveSaveContract() {
        XCTAssertEqual(DeterministicParser.parse("bench 100x100")?.first?.reps, WorkoutValidator.maxReps)
        XCTAssertEqual(DeterministicParser.parse("bench 2 sets of 100 reps")?.count, 2)

        XCTAssertNil(DeterministicParser.parse("bench 100x101"))
        XCTAssertNil(DeterministicParser.parse("bench 2 sets of 101 reps"))
        XCTAssertNil(DeterministicParser.parse("bw x150"))
    }

    func testDeclinesAmbiguousAndProse() {
        XCTAssertEqual(DeterministicParser.parse("135x8x3")?.count, 3, "large leading number is weight x reps x sets")
        XCTAssertNil(DeterministicParser.parse("just did a great workout"))
        XCTAssertNil(DeterministicParser.parse("bench 135"), "weight with no reps is incomplete")
        XCTAssertNil(DeterministicParser.parse(""))
        XCTAssertNil(DeterministicParser.parse("   "))
    }

    func testDeclinesRepsAboveTheCap() {
        // The parser shares WorkoutValidator.repsRange, so an over-cap entry
        // declines at parse instead of being confirmed and then rejected at save.
        XCTAssertNil(DeterministicParser.parse("squat 225x101"))
        XCTAssertNil(DeterministicParser.parse("1x150"))
        XCTAssertEqual(DeterministicParser.parse("squat 225x100")?.count, 1, "the cap itself still parses")
    }

    /// The whole point of the spine: a parsed entry is exactly what `save`
    /// consumes — chat/quick-log/parser all converge on the one write path.
    func testParsedSetsFlowThroughTheSavePath() throws {
        let path = NSTemporaryDirectory() + "wcl-parser-\(UUID().uuidString).sqlite"
        let store = WorkoutStore(db: try SQLiteDB(path: path))
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))

        let sets = try XCTUnwrap(DeterministicParser.parse("bench 135 for 8,8,7"))
        let result = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: sets))

        XCTAssertEqual(result.setIDs.count, 3)
        let stored = try store.sets(inSession: result.sessionID)
        XCTAssertEqual(stored.map(\.reps), [8, 8, 7])
        XCTAssertEqual(stored.map(\.setIndex), [1, 2, 3])

        // "bench" resolved through the alias map to the seeded canonical lift.
        let benchID = try XCTUnwrap(store.resolveExercise("bench"))
        XCTAssertTrue(stored.allSatisfy { $0.exerciseID == benchID })
    }

    /// A bare scheme parses (the numeric spec is valid) but carries an empty
    /// exercise name — its exercise comes from context. Contract: it won't
    /// persist until an exercise is attached. Parser generous, saver strict.
    func testBareSchemeParsesWithEmptyNameAndDoesNotPersist() throws {
        let sets = try XCTUnwrap(DeterministicParser.parse("3x10"))
        XCTAssertEqual(sets.count, 3)
        XCTAssertTrue(sets.allSatisfy { $0.exerciseName.isEmpty }, "a bare scheme has no exercise")

        let path = NSTemporaryDirectory() + "wcl-bare-\(UUID().uuidString).sqlite"
        let store = WorkoutStore(db: try SQLiteDB(path: path))
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        try store.migrate()

        XCTAssertThrowsError(try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: sets))) {
            XCTAssertEqual($0 as? ParseError, .emptyExerciseName)
        }
        XCTAssertEqual(try store.sessionCount(), 0)
    }

    func testExerciseNameTrailingPunctuationIsIgnored() {
        XCTAssertEqual(DeterministicParser.parse("Bench Press: 135x8")?.first?.exerciseName, "bench press")
        XCTAssertEqual(DeterministicParser.parse("Bench Press - 135x8")?.first?.exerciseName, "bench press")
        XCTAssertEqual(DeterministicParser.parse("Chest-Supported Row 90x10")?.first?.exerciseName, "chest-supported row")
    }

    // MARK: - Decline diagnosis (so the status card can say *why*)

    func testDiagnoseRepRanges() {
        XCTAssertEqual(DeterministicParser.diagnoseDecline("bench 8-10"), .repRange)
        XCTAssertEqual(DeterministicParser.diagnoseDecline("squat 5–8"), .repRange)
        XCTAssertEqual(DeterministicParser.diagnoseDecline("rows 8 to 12"), .repRange)
    }

    func testDiagnoseCardio() {
        XCTAssertEqual(DeterministicParser.diagnoseDecline("5k 25min"), .cardio)
        XCTAssertEqual(DeterministicParser.diagnoseDecline("run 3km easy"), .cardio)
        XCTAssertEqual(DeterministicParser.diagnoseDecline("row 20 minutes"), .cardio)
    }

    func testDiagnoseMultiExercise() {
        XCTAssertEqual(DeterministicParser.diagnoseDecline("bench 135x8 squat 225x5"), .multiExercise)
        XCTAssertEqual(DeterministicParser.diagnoseDecline("bench 135x8 + curl 30x10"), .multiExercise)
    }

    func testDiagnoseIncompleteWeight() {
        XCTAssertEqual(DeterministicParser.diagnoseDecline("bench 135"), .incompleteWeight)
        XCTAssertEqual(DeterministicParser.diagnoseDecline("ohp 95"), .incompleteWeight)
        XCTAssertNil(DeterministicParser.diagnoseDecline("pull up 15"))
    }

    func testDiagnoseAmbiguousTripleX() {
        XCTAssertEqual(DeterministicParser.diagnoseDecline("squat 5x5x5"), .ambiguousTripleX)
        XCTAssertEqual(DeterministicParser.diagnoseDecline("8x8x8"), .ambiguousTripleX)
    }

    func testDiagnoseReturnsNilWhenNoMatch() {
        XCTAssertNil(DeterministicParser.diagnoseDecline("felt strong today"))
        XCTAssertNil(DeterministicParser.diagnoseDecline(""))
    }

    /// Confidently-parseable entries should never be flagged as declines by the
    /// diagnose path — the orchestrator only consults it when `parse` returned
    /// nil, but a hostile call here proves the diagnose function is a *heuristic*,
    /// not authoritative. We still want it to behave reasonably on a good line.
    func testDiagnoseDoesNotFalsePositiveOnValidEntries() {
        // 135x8x3 — confident weight (3 digits leading), parses fine. Won't be
        // flagged ambiguous because the regex caps at 2 digits.
        XCTAssertNil(DeterministicParser.diagnoseDecline("bench 135x8x3"))
    }
}
