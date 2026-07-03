import XCTest
@testable import WorkoutChatLog

/// The forgiving recovery extractor — the never-dead-end path the screenshots
/// hammered: weight-first order, the `8×160×3` triple, per-set rep lists, and
/// bodyweight defaulting.
final class ForgivingParserTests: XCTestCase {

    private func parse(_ s: String) -> [SetDraft]? { ForgivingParser.parse(s) }

    func testWeightFirstOrder() throws {
        // "120 lbs leg ext 3 set" — weight first, name in the middle, "3 set".
        let sets = try XCTUnwrap(parse("120 lbs leg ext 3 set"))
        XCTAssertEqual(sets.count, 3)
        XCTAssertEqual(sets.first?.exerciseName, "leg ext")
        XCTAssertTrue(sets.allSatisfy { $0.weight == 120 && $0.unit == .lb })
        XCTAssertTrue(sets.allSatisfy { $0.loadKind == .external })
        XCTAssertTrue(sets.allSatisfy { $0.reps == 0 }, "reps stay unset until the user confirms")
    }

    func testWeightInMiddleOfTriple() throws {
        // "leg curl 8x160x3" → 160 is the load, 8 reps, 3 sets.
        let sets = try XCTUnwrap(parse("leg curl 8x160x3"))
        XCTAssertEqual(sets.count, 3)
        XCTAssertEqual(sets.first?.exerciseName, "leg curl")
        XCTAssertTrue(sets.allSatisfy { $0.weight == 160 && $0.reps == 8 })
        XCTAssertTrue(sets.allSatisfy { $0.loadKind == .external })
    }

    func testWeightLastTriple() throws {
        // "bench 3x10x135" = sets × reps × weight → 3 sets of 10 @ 135 (not 10×3).
        let sets = try XCTUnwrap(parse("bench 3x10x135"))
        XCTAssertEqual(sets.count, 3)
        XCTAssertTrue(sets.allSatisfy { $0.reps == 10 && $0.weight == 135 })
        XCTAssertEqual(sets.first?.exerciseName, "bench")
    }

    func testWeightFirstTriple() throws {
        // "bench 135x8x3" = weight × reps × sets → 3 sets of 8 @ 135.
        let sets = try XCTUnwrap(parse("bench 135x8x3"))
        XCTAssertEqual(sets.count, 3)
        XCTAssertTrue(sets.allSatisfy { $0.reps == 8 && $0.weight == 135 })
    }

    func testDecimalCommaWeight() throws {
        // A kg/lb decimal written with a comma must parse as 120.5, not collapse to
        // 120 or mis-slot the fractional digit as reps (kg-locale users write "120,5").
        let sets = try XCTUnwrap(parse("120,5 lbs leg ext 3 set"))
        XCTAssertEqual(sets.count, 3)
        XCTAssertTrue(sets.allSatisfy { $0.weight == 120.5 && $0.unit == .lb })
    }

    func testAbsurdXChainClampsInsteadOfCrashing() {
        // Uncapped x-chain values used to trap Int(Double). They now clamp; the point
        // is that parsing returns instead of crashing, with no absurd rep count.
        let sets = ForgivingParser.parse("bench 3x99999999999999999999")
        for s in sets ?? [] { XCTAssertLessThanOrEqual(s.reps, 1000) }
    }

    func testThousandsSeparatorWeightIsNotDecimal() throws {
        // "1,000" is 1000, not 1.0 — grouped thousands must survive the comma-decimal fix.
        let sets = try XCTUnwrap(parse("1,000 lbs leg ext 3 set"))
        XCTAssertEqual(sets.count, 3)
        XCTAssertTrue(sets.allSatisfy { $0.weight == 1000 && $0.unit == .lb })
    }

    func testPerSetRepListBodyweight() throws {
        let sets = try XCTUnwrap(parse("chinups 7,3"))
        XCTAssertEqual(sets.map(\.reps), [7, 3])
        XCTAssertEqual(sets.first?.exerciseName, "chinups")
        XCTAssertTrue(sets.allSatisfy { $0.loadKind == .bodyweight && $0.weight == 0 })
    }

    func testThenSeparatedRepList() throws {
        let sets = try XCTUnwrap(parse("chin ups 7 then 3"))
        XCTAssertEqual(sets.map(\.reps), [7, 3])
        XCTAssertEqual(sets.first?.exerciseName, "chin ups")
        XCTAssertTrue(sets.allSatisfy { $0.loadKind == .bodyweight })
    }

    func testProseRepListStripsFillerAndPunctuation() throws {
        let sets = try XCTUnwrap(parse("chinups, 7 of them then 3 of them"))
        XCTAssertEqual(sets.map(\.reps), [7, 3])
        XCTAssertEqual(sets.first?.exerciseName, "chinups", "trailing comma is cleaned off the name")
    }

    func testWeightNoReps() throws {
        let sets = try XCTUnwrap(parse("bench 135"))
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.weight, 135)
        XCTAssertEqual(sets.first?.reps, 0)
        XCTAssertEqual(sets.first?.loadKind, .external)
        XCTAssertEqual(sets.first?.exerciseName, "bench")
    }

    func testAmbiguousTripleStaysNameless() throws {
        let sets = try XCTUnwrap(parse("8x3x4"))
        XCTAssertEqual(sets.count, 8)
        XCTAssertTrue(sets.allSatisfy { $0.reps == 3 })
        XCTAssertEqual(sets.first?.exerciseName, "")
    }

    func testExplicitBodyweightChain() throws {
        // "bw" is the load slot, not a count: "chin up bw x 8 x 3" = 3 BW sets of 8.
        let triple = try XCTUnwrap(parse("chin up bw x 8 x 3"))
        XCTAssertEqual(triple.count, 3)
        XCTAssertTrue(triple.allSatisfy { $0.reps == 8 && $0.loadKind == .bodyweight && $0.weight == 0 })
        XCTAssertEqual(triple.first?.exerciseName, "chin up")

        let single = try XCTUnwrap(parse("pull up bw x 8"))
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first?.reps, 8)
        XCTAssertEqual(single.first?.loadKind, .bodyweight)
    }

    func testBodyweightSchemeDefaultsToBodyweight() throws {
        let sets = try XCTUnwrap(parse("pushup 3x10"))
        XCTAssertEqual(sets.count, 3)
        XCTAssertTrue(sets.allSatisfy { $0.reps == 10 && $0.loadKind == .bodyweight })
    }

    func testNumericPrefixNameIsPreserved() throws {
        // "45 degree back extension" — the leading number is part of the name, not
        // a count, so it must survive name cleanup.
        let sets = try XCTUnwrap(parse("45 degree back extension 8 reps"))
        XCTAssertEqual(sets.first?.exerciseName, "45 degree back extension")
        XCTAssertEqual(sets.first?.reps, 8)
    }

    func testPlusSeparatedRepList() throws {
        // "7+3" is a rep list, not a superset — the glued "+" splits like ",".
        let sets = try XCTUnwrap(parse("chinups 7+3"))
        XCTAssertEqual(sets.map(\.reps), [7, 3])
        XCTAssertEqual(sets.first?.exerciseName, "chinups")
        XCTAssertTrue(sets.allSatisfy { $0.loadKind == .bodyweight })
    }

    func testRepRangeLeavesRepsUnset() throws {
        // "8-10" is consumed, never resolved to an endpoint the user didn't
        // state: the load and name recover, reps stay 0 (the unset sentinel).
        let sets = try XCTUnwrap(parse("bench 135 8-10"))
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.weight, 135)
        XCTAssertEqual(sets.first?.reps, 0, "a range never becomes a picked endpoint")
        XCTAssertEqual(sets.first?.exerciseName, "bench")
    }

    func testRepRangeWithGluedSetCount() throws {
        // "3x8-10" — the number the range hangs off via `x` is the set count.
        let sets = try XCTUnwrap(parse("curls 3x8-10"))
        XCTAssertEqual(sets.count, 3)
        XCTAssertTrue(sets.allSatisfy { $0.reps == 0 })
        XCTAssertEqual(sets.first?.exerciseName, "curls")
    }

    func testWordedRepRangeStillRecoversTheLoad() throws {
        let sets = try XCTUnwrap(parse("rows 8 to 12 at 100"))
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.weight, 100)
        XCTAssertEqual(sets.first?.reps, 0)
        XCTAssertEqual(sets.first?.exerciseName, "rows")
    }

    func testSpacedUnitAndPunctuation() throws {
        XCTAssertEqual(try XCTUnwrap(parse("bench 135 lb")).first?.unit, .lb)
        let kg = try XCTUnwrap(parse("frobnicator 60kg?"))
        XCTAssertEqual(kg.first?.weight, 60)
        XCTAssertEqual(kg.first?.unit, .kg)
        XCTAssertEqual(kg.first?.exerciseName, "frobnicator")
    }
}
