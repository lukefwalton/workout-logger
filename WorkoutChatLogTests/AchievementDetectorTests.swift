import XCTest
@testable import WorkoutChatLog

/// Pure, deterministic PR-detection logic (§4) — honest-or-nothing edge cases,
/// the Epley formula, and the headline strings. No store, no UI. Prototyped in
/// Python first; these mirror those fixtures.
final class AchievementDetectorTests: XCTestCase {

    // MARK: - Builders

    private func ext(_ weight: Double, _ reps: Int, unit: WeightUnit = .lb, ex: Int64 = 1) -> AchievementDetector.SetFact {
        AchievementDetector.SetFact(exerciseID: ex, loadKind: .external, weight: weight, unit: unit, reps: reps)
    }
    private func bw(_ reps: Int, ex: Int64 = 1) -> AchievementDetector.SetFact {
        AchievementDetector.SetFact(exerciseID: ex, loadKind: .bodyweight, weight: nil, unit: nil, reps: reps)
    }
    private func unspecified(_ reps: Int, ex: Int64 = 1) -> AchievementDetector.SetFact {
        AchievementDetector.SetFact(exerciseID: ex, loadKind: .unspecified, weight: nil, unit: nil, reps: reps)
    }

    private func detect(_ saved: [AchievementDetector.SetFact],
                        prior: [AchievementDetector.SetFact],
                        ex: Int64 = 1, name: String = "Bench Press") -> [Achievement] {
        AchievementDetector.achievements(saved: saved, priorByExercise: [ex: prior], nameByExercise: [ex: name])
    }

    // MARK: - Honest-or-nothing

    func testFirstEverLogIsNotAPR() {
        XCTAssertTrue(detect([ext(135, 8)], prior: []).isEmpty, "first time logged is never a PR")
    }

    func testEstimatedOneRepMaxBeaterFires() {
        let prs = detect([ext(140, 8)], prior: [ext(135, 8)])
        XCTAssertEqual(prs.count, 1)
        XCTAssertEqual(prs.first?.kind, .estimatedOneRepMax)
        XCTAssertEqual(prs.first?.value ?? 0, OneRepMax.epley(weight: 140, reps: 8), accuracy: 1e-9)
        XCTAssertEqual(prs.first?.unit, .lb)
    }

    func testWorseSetIsNotAPR() {
        XCTAssertTrue(detect([ext(130, 8)], prior: [ext(135, 8)]).isEmpty)
    }

    func testTieIsNotAPR() {
        XCTAssertTrue(detect([ext(135, 8)], prior: [ext(135, 8)]).isEmpty, "ties are not PRs")
    }

    func testEqualEstimatedOneRepMaxDifferentRepSchemeIsNotAPR() {
        // 120×10 → e1RM 160. A weight at 5 reps giving the same e1RM is a tie, not a PR.
        let equalWeight = 160 / (1 + 5.0 / 30)
        XCTAssertTrue(detect([ext(equalWeight, 5)], prior: [ext(120, 10)]).isEmpty)
    }

    func testUnspecifiedSavedAgainstLoadedPriorIsNotAWeightPR() {
        // Saved set has no usable weight, and there's no bodyweight prior to beat.
        XCTAssertTrue(detect([unspecified(20)], prior: [ext(135, 8)]).isEmpty)
    }

    func testZeroWeightExternalIsNotAWeightPR() {
        XCTAssertTrue(detect([ext(0, 8)], prior: [ext(135, 8)]).isEmpty, "a zero-weight set never beats a real load")
    }

    // MARK: - Weight-for-reps

    func testWeightForRepsFiresWhenEstimatedOneRepMaxNotBeaten() {
        // Prior best e1RM is 135×10 (180); today's 140×8 (177.3) does not beat it,
        // but 140 > 135 at the 8-rep count the lift has done before → weight PR.
        let prs = detect([ext(140, 8)], prior: [ext(135, 10), ext(135, 8)])
        XCTAssertEqual(prs.first?.kind, .weightForReps)
        XCTAssertEqual(prs.first?.value, 140)
        XCTAssertEqual(prs.first?.reps, 8)
    }

    func testWeightForRepsRequiresPriorAtSameRepCount() {
        // Only prior is 135×10; 140×8 has no 8-rep history to beat, and e1RM (177.3)
        // is below 135×10's 180 → nothing.
        XCTAssertTrue(detect([ext(140, 8)], prior: [ext(135, 10)]).isEmpty)
    }

    func testWeightForRepsWorksAboveEpleyRepCap() {
        // 15 reps is past the e1RM cap (dropped there), but a heavier 15-rep set is
        // still an honest weight-at-reps PR.
        let prs = detect([ext(110, 15)], prior: [ext(100, 15)])
        XCTAssertEqual(prs.first?.kind, .weightForReps)
        XCTAssertEqual(prs.first?.reps, 15)
    }

    // MARK: - Max reps (bodyweight)

    func testBodyweightRepPRFires() {
        let prs = detect([bw(12)], prior: [bw(10)], name: "Pull-Up")
        XCTAssertEqual(prs.first?.kind, .maxReps)
        XCTAssertEqual(prs.first?.value, 12)
        XCTAssertNil(prs.first?.unit, "a rep PR has no weight unit")
    }

    func testBodyweightRepTieIsNotAPR() {
        XCTAssertTrue(detect([bw(10)], prior: [bw(10)], name: "Pull-Up").isEmpty)
    }

    func testBodyweightFirstEverIsNotAPR() {
        XCTAssertTrue(detect([bw(10)], prior: [], name: "Pull-Up").isEmpty)
    }

    func testUnspecifiedHistoryNeverYieldsAMaxRepsPR() {
        // `.unspecified` = load unknown/unconfirmed, not a genuine bodyweight set.
        // More unspecified reps must NOT surface a rep PR (would invent one from data
        // the user never committed to).
        XCTAssertTrue(detect([unspecified(12)], prior: [unspecified(10)]).isEmpty,
                      "unspecified loads never PR — only genuine bodyweight does")
        // And an unspecified set never blocks/false-fires against bodyweight history.
        XCTAssertTrue(detect([unspecified(12)], prior: [bw(10)], name: "Pull-Up").isEmpty,
                      "an unspecified saved set is not a bodyweight rep PR")
    }

    // MARK: - Mixed units (never silently converted; compare within a unit)

    func testMixedUnitDoesNotFalselyFireEstimatedOneRepMax() {
        // 100 kg×8 is heavier in reality than 150 lb×8, so the lb set is not a PR.
        // Comparing raw numbers would wrongly fire it; per-unit comparison must not.
        XCTAssertTrue(detect([ext(150, 8, unit: .lb)], prior: [ext(100, 8, unit: .kg)]).isEmpty,
                      "no cross-unit PR — the app never silently converts lb↔kg")
    }

    func testMixedUnitDoesNotFalselyFireWeightForReps() {
        XCTAssertTrue(detect([ext(120, 5, unit: .lb)], prior: [ext(100, 5, unit: .kg)]).isEmpty,
                      "weight-at-reps compares within a unit only")
    }

    func testSameUnitPRStillFiresAmidMixedHistory() {
        // The lb set beats prior lb history; the kg prior is ignored, not converted.
        let prs = detect([ext(140, 8, unit: .lb)], prior: [ext(100, 8, unit: .kg), ext(135, 8, unit: .lb)])
        XCTAssertEqual(prs.first?.kind, .estimatedOneRepMax)
        XCTAssertEqual(prs.first?.unit, .lb)
    }

    func testWeightForRepsHeadlineRanksByOwnUnitImprovementNotRawWeight() {
        // Both units PR at 8 reps: lb beats its prior by 5, kg beats its prior by 10.
        // The kg set must headline (bigger improvement over its own history) even though
        // 110 < 140 as a raw number — raw cross-unit weight is never the tie-break.
        // (e1RM doesn't fire: each unit's saved e1RM only beats its own-unit prior by a
        // hair, and we force weight-for-reps by giving each a heavier same-rep prior.)
        let saved = [ext(140, 8, unit: .lb), ext(110, 8, unit: .kg)]
        let prior = [ext(135, 8, unit: .lb), ext(160, 5, unit: .lb),   // lb e1RM already high
                     ext(100, 8, unit: .kg), ext(150, 5, unit: .kg)]   // kg e1RM already high
        let prs = AchievementDetector.achievements(saved: saved,
                                                   priorByExercise: [1: prior], nameByExercise: [1: "Bench Press"])
        XCTAssertEqual(prs.first?.kind, .weightForReps)
        XCTAssertEqual(prs.first?.unit, .kg, "kg improved more over its own-unit history")
        XCTAssertEqual(prs.first?.value, 110)
    }

    // MARK: - Precedence (one load style per entry; loaded beats reps)

    func testExternalSetTakesLoadedPRPathNotMaxReps() {
        // A loaded entry routes to the loaded PR, never the bodyweight rep PR — even
        // though the lift also has bodyweight history with more reps.
        let saved = [ext(140, 8)]
        let prior: [Int64: [AchievementDetector.SetFact]] = [1: [ext(135, 8), bw(20)]]
        let prs = AchievementDetector.achievements(saved: saved, priorByExercise: prior,
                                                   nameByExercise: [1: "Bench Press"])
        XCTAssertEqual(prs.first?.kind, .estimatedOneRepMax, "external presence ⇒ loaded path")
    }

    // MARK: - Shape

    func testOnePRPerExerciseOrderedByID() {
        let saved = [ext(140, 8, ex: 1), bw(12, ex: 2)]
        let prior: [Int64: [AchievementDetector.SetFact]] = [1: [ext(135, 8, ex: 1)], 2: [bw(10, ex: 2)]]
        let names: [Int64: String] = [1: "Bench Press", 2: "Pull-Up"]
        let prs = AchievementDetector.achievements(saved: saved, priorByExercise: prior, nameByExercise: names)
        XCTAssertEqual(prs.map(\.exerciseID), [1, 2], "one headline PR per exercise, ordered by id")
        XCTAssertEqual(prs.map(\.kind), [.estimatedOneRepMax, .maxReps])
    }

    // MARK: - Formula + headlines

    func testEpleyFormulaMatchesFixture() {
        XCTAssertEqual(OneRepMax.epley(weight: 100, reps: 10), 100 * (1 + 10.0 / 30), accuracy: 1e-9)
        XCTAssertEqual(ProgressAnalytics.e1rmRepCap, OneRepMax.repCap, "single-sourced rep cap")
    }

    func testHeadlinesAreHonestAndLabelled() {
        let e1rm = Achievement(kind: .estimatedOneRepMax, exerciseID: 1, exerciseName: "Bench Press",
                               value: 177.33, reps: nil, unit: .lb)
        XCTAssertEqual(e1rm.headline, "New estimated 1RM on Bench Press — 177 lb")

        let wfr = Achievement(kind: .weightForReps, exerciseID: 1, exerciseName: "Back Squat",
                              value: 225, reps: 5, unit: .lb)
        XCTAssertEqual(wfr.headline, "New weight PR on Back Squat — 225 lb × 5")

        let reps = Achievement(kind: .maxReps, exerciseID: 1, exerciseName: "Pull-Up",
                               value: 1, reps: nil, unit: nil)
        XCTAssertEqual(reps.headline, "New rep PR on Pull-Up — 1 rep", "singular rep, no fabricated unit")
    }

    // MARK: - Weighted calisthenics (bodyweightPlus / assisted)

    private func plus(_ added: Double, _ reps: Int, unit: WeightUnit = .lb, ex: Int64 = 1) -> AchievementDetector.SetFact {
        AchievementDetector.SetFact(exerciseID: ex, loadKind: .bodyweightPlus, weight: added, unit: unit, reps: reps)
    }
    private func assisted(_ assist: Double, _ reps: Int, unit: WeightUnit = .lb, ex: Int64 = 1) -> AchievementDetector.SetFact {
        AchievementDetector.SetFact(exerciseID: ex, loadKind: .assisted, weight: assist, unit: unit, reps: reps)
    }

    func testWeightedCalisthenicsBeatingAddedLoadFiresAPR() {
        // Pull-up with a 25 lb belt at 5 reps beats prior 20 lb × 5.
        let prs = detect([plus(25, 5)], prior: [plus(20, 5)], name: "Pull-Up")
        XCTAssertEqual(prs.first?.kind, .weightForReps)
        XCTAssertEqual(prs.first?.value, 25)
        XCTAssertEqual(prs.first?.reps, 5)
    }

    func testWeightedCalisthenicsFirstEverIsNotAPR() {
        XCTAssertTrue(detect([plus(20, 5)], prior: [], name: "Pull-Up").isEmpty,
                      "first weighted attempt at this rep count has nothing to beat")
    }

    func testAssistedPRFiresWhenLessHelpUsed() {
        // Assisted pull-up with 30 lb of help is a PR over a prior set with 50.
        let prs = detect([assisted(30, 8)], prior: [assisted(50, 8)], name: "Assisted Pull-Up")
        XCTAssertEqual(prs.first?.kind, .weightForReps)
        XCTAssertEqual(prs.first?.value, 30, "less assistance is the better number")
    }

    func testAssistedMoreHelpThanPriorIsNotAPR() {
        XCTAssertTrue(detect([assisted(60, 8)], prior: [assisted(50, 8)], name: "Assisted Pull-Up").isEmpty)
    }

    func testWeightedCalisthenicsDoesNotCompareAcrossLoadKinds() {
        // A pure bodyweight prior is not the right benchmark for a weighted PR —
        // the answer must be no PR (no same-loadKind prior to beat).
        XCTAssertTrue(detect([plus(20, 5)], prior: [bw(5)], name: "Pull-Up").isEmpty)
    }
}
