import XCTest
@testable import WorkoutChatLog

/// The FM-free core of PR 8: the orchestrator's layer ordering and the defensive
/// `ModelDraftMapping`. No FoundationModels import anywhere — the real SDK parser
/// is verified on-device; here the protocol seam is exercised with a fake.
final class WorkoutParsingTests: XCTestCase {

    // MARK: - DeterministicWorkoutParsing adapter

    func testDeterministicAdapterDraftsAWellFormedSet() async {
        let outcome = await DeterministicWorkoutParsing().parse("bench 135x8", context: [])
        guard case .draft(let result) = outcome else { return XCTFail("expected a draft") }
        XCTAssertEqual(result.source, .deterministic)
        XCTAssertEqual(result.sets.count, 1)
        XCTAssertEqual(result.sets.first?.reps, 8)
    }

    func testDeterministicAdapterNeverAsksAndDeclinesProse() async {
        let outcome = await DeterministicWorkoutParsing().parse("did a great chest workout", context: [])
        XCTAssertEqual(outcome, .declined, "the deterministic path returns draft or declined only — never a clarification")
    }

    // MARK: - Orchestrator ordering (§1.1 determinism first, ML last)

    func testOrchestratorDeterministicWinsAndFMIsNotConsulted() async {
        let fm = FakeWorkoutParsing(.clarification(ClarificationPrompt(message: "which?", suggestedReplies: [])))
        let orchestrator = WorkoutParserOrchestrator(deterministic: DeterministicWorkoutParsing(), foundation: fm)

        let outcome = await orchestrator.parse("bench 135x8", context: [])
        guard case .draft(let result) = outcome else { return XCTFail("expected deterministic draft") }
        XCTAssertEqual(result.source, .deterministic)
        XCTAssertEqual(fm.callCount, 0, "FM must fire only when the deterministic layer declines")
    }

    func testOrchestratorFallsBackToFMOnlyOnDecline() async {
        let fm = FakeWorkoutParsing(.draftFixture())
        let orchestrator = WorkoutParserOrchestrator(deterministic: DeterministicWorkoutParsing(), foundation: fm)

        let outcome = await orchestrator.parse("did chest thing for a few", context: [])
        guard case .draft(let result) = outcome else { return XCTFail("expected the FM draft") }
        XCTAssertEqual(result.source, .appleIntelligence)
        XCTAssertEqual(fm.callCount, 1)
    }

    func testOrchestratorDeclinesWhenFMAbsent() async {
        let orchestrator = WorkoutParserOrchestrator(deterministic: DeterministicWorkoutParsing(), foundation: nil)
        let outcome = await orchestrator.parse("totally unparseable prose", context: [])
        XCTAssertEqual(outcome, .declined, "no FM layer (unavailable / not built) → declined, never a crash")
    }

    func testOrchestratorForwardsContextToFM() async {
        let fm = FakeWorkoutParsing(.declined)
        let orchestrator = WorkoutParserOrchestrator(deterministic: DeterministicWorkoutParsing(), foundation: fm)
        _ = await orchestrator.parse("chest thing", context: ["Dumbbell Bench Press"])
        XCTAssertEqual(fm.calls.first?.context, ["Dumbbell Bench Press"])
    }

    // MARK: - ModelDraftMapping (the defensive, all-or-nothing translation)

    func testMappingValidSet() {
        let set = ModelDraftMapping.setDraft(amount: 135, unit: "lb", loadKind: "external",
                                             reps: 8, rir: 2, setType: "working",
                                             exerciseName: "Bench Press", sourceText: "src")
        XCTAssertEqual(set?.weight, 135)
        XCTAssertEqual(set?.loadKind, .external)
        XCTAssertEqual(set?.rir, 2)
        XCTAssertEqual(set?.unit, .lb)
    }

    func testMappingRejectsUnknownEnums() {
        XCTAssertNil(ModelDraftMapping.setDraft(amount: 100, unit: "lb", loadKind: "rocket",
                                                reps: 8, rir: nil, setType: "working",
                                                exerciseName: "x", sourceText: nil))
        XCTAssertNil(ModelDraftMapping.setDraft(amount: 100, unit: "lb", loadKind: "external",
                                                reps: 8, rir: nil, setType: "supermax",
                                                exerciseName: "x", sourceText: nil))
    }

    func testMappingRejectsOutOfRangeRepsAndRIR() {
        XCTAssertNil(ModelDraftMapping.setDraft(amount: 100, unit: nil, loadKind: "external",
                                                reps: 0, rir: nil, setType: "working",
                                                exerciseName: "x", sourceText: nil))
        XCTAssertNil(ModelDraftMapping.setDraft(amount: 100, unit: nil, loadKind: "external",
                                                reps: 200, rir: nil, setType: "working",
                                                exerciseName: "x", sourceText: nil))
        XCTAssertNil(ModelDraftMapping.setDraft(amount: 100, unit: nil, loadKind: "external",
                                                reps: 8, rir: 11, setType: "working",
                                                exerciseName: "x", sourceText: nil))
    }

    func testMappingRejectsStatedButUnreadableUnit() {
        XCTAssertNil(ModelDraftMapping.setDraft(amount: 100, unit: "stone", loadKind: "external",
                                                reps: 8, rir: nil, setType: "working",
                                                exerciseName: "x", sourceText: nil))
    }

    func testMappingDefaultsMissingUnitToLb() {
        let set = ModelDraftMapping.setDraft(amount: 100, unit: nil, loadKind: "external",
                                             reps: 8, rir: nil, setType: "working",
                                             exerciseName: "x", sourceText: nil)
        XCTAssertEqual(set?.unit, .lb)
    }

    func testMappingNormalizesExternalZeroToUnspecified() {
        let set = ModelDraftMapping.setDraft(amount: 0, unit: nil, loadKind: "external",
                                             reps: 10, rir: nil, setType: "working",
                                             exerciseName: "Squat", sourceText: nil)
        XCTAssertEqual(set?.loadKind, .unspecified, "an external load with no weight is unspecified until confirmed, not a fabricated 0 lb")
        XCTAssertEqual(set?.weight, 0)
    }

    func testMappingPreservesGenuineBodyweight() {
        let set = ModelDraftMapping.setDraft(amount: 0, unit: nil, loadKind: "bodyweight",
                                             reps: 12, rir: nil, setType: "working",
                                             exerciseName: "Push-Up", sourceText: nil)
        XCTAssertEqual(set?.loadKind, .bodyweight)
    }

    func testMappingDeclinesWholesaleOnAnyBadSet() {
        let good = ModelDraftMapping.setDraft(amount: 135, unit: "lb", loadKind: "external",
                                              reps: 8, rir: nil, setType: "working",
                                              exerciseName: "Bench Press", sourceText: nil)
        XCTAssertNotNil(good)
        // One readable set, one unreadable → the whole entry declines (never drop a set).
        XCTAssertNil(ModelDraftMapping.result(mappedSets: [good, nil], source: .appleIntelligence, warning: nil))
    }

    func testMappingResultRequiresAtLeastOneSet() {
        XCTAssertNil(ModelDraftMapping.result(mappedSets: [], source: .appleIntelligence, warning: nil))
    }

    func testMappingResultTrimsBlankWarningToNil() {
        let good = ModelDraftMapping.setDraft(amount: 135, unit: "lb", loadKind: "external",
                                              reps: 8, rir: nil, setType: "working",
                                              exerciseName: "Bench Press", sourceText: nil)
        let result = ModelDraftMapping.result(mappedSets: [good], source: .appleIntelligence, warning: "   ")
        XCTAssertNil(result?.warning)
    }

    func testClarificationCapsRepliesAtThreeAndDropsBlanks() {
        let prompt = ModelDraftMapping.clarification(message: "  Which bench variation?  ",
                                                     replies: ["DB Bench", "", "DB Fly", "Incline", "Decline"])
        XCTAssertEqual(prompt?.message, "Which bench variation?")
        XCTAssertEqual(prompt?.suggestedReplies, ["DB Bench", "DB Fly", "Incline"])
    }

    func testClarificationDeclinesOnEmptyQuestion() {
        XCTAssertNil(ModelDraftMapping.clarification(message: "   ", replies: ["a"]))
    }
}
