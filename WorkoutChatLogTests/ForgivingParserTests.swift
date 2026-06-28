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

    func testSpacedUnitAndPunctuation() throws {
        XCTAssertEqual(try XCTUnwrap(parse("bench 135 lb")).first?.unit, .lb)
        let kg = try XCTUnwrap(parse("frobnicator 60kg?"))
        XCTAssertEqual(kg.first?.weight, 60)
        XCTAssertEqual(kg.first?.unit, .kg)
        XCTAssertEqual(kg.first?.exerciseName, "frobnicator")
    }
}
