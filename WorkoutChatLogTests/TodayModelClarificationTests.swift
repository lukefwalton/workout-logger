import XCTest
@testable import WorkoutChatLog

/// PR 8 at the `TodayModel` level: the clarification state machine driven by a fake
/// `WorkoutParsing` (no FoundationModels import). Proves the question/reply loop,
/// the round cap, the "type it manually" hatch, the AI-source flag, and that
/// nothing persists before confirm.
@MainActor
final class TodayModelClarificationTests: XCTestCase {

    private var path: String!
    private var store: WorkoutStore!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "wcl-clar-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: path))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
        defaultsSuiteName = "wcl-clar-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        store = nil
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func model(_ parser: WorkoutParsing) -> TodayModel {
        TodayModel(store: store, parser: parser, planDefaults: defaults)
    }

    private func clarification(_ message: String, _ replies: [String]) -> ParseOutcome {
        .clarification(ClarificationPrompt(message: message, suggestedReplies: replies))
    }

    func testClarificationSurfacesQuestionWithReplies() async {
        let m = model(FakeWorkoutParsing(clarification("Which bench variation?", ["DB Bench", "DB Fly"])))
        m.inputText = "did chest thing with 45s for a few"
        await m.parse()

        guard case .needsClarification(let prompt) = m.status else { return XCTFail("expected a clarification") }
        XCTAssertEqual(prompt.message, "Which bench variation?")
        XCTAssertLessThanOrEqual(prompt.suggestedReplies.count, 3)
        XCTAssertNil(m.pending, "a clarification is not a draft — nothing to confirm yet")
    }

    func testReplyReinvokesParseWithOriginalInputAndContext() async {
        let fake = FakeWorkoutParsing([clarification("Which one?", ["DB Bench Press"]), .draftFixture()])
        let m = model(fake)
        m.inputText = "did chest thing"
        await m.parse()
        await m.replyToClarification("DB Bench Press")

        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertEqual(fake.calls[0].input, "did chest thing")
        XCTAssertEqual(fake.calls[0].context, [])
        XCTAssertEqual(fake.calls[1].input, "did chest thing", "the original entry is preserved as context")
        XCTAssertEqual(fake.calls[1].context, ["DB Bench Press"], "the chosen reply is appended")
    }

    func testReplyYieldingDraftMovesToConfirmWithAINote() async {
        let fake = FakeWorkoutParsing([clarification("Which one?", ["DB Bench Press"]), .draftFixture()])
        let m = model(fake)
        m.inputText = "did chest thing"
        await m.parse()
        await m.replyToClarification("DB Bench Press")

        XCTAssertEqual(m.status, .idle)
        XCTAssertNotNil(m.pending)
        XCTAssertEqual(m.pendingParseSource, .appleIntelligence, "FM drafts show the Apple Intelligence note")
    }

    func testRoundCapStopsAtTwoThenDeclines() async {
        // Always asks; the user keeps replying. Cap = 2 clarifications, then declined.
        let fake = FakeWorkoutParsing([
            clarification("Q1", ["a"]),
            clarification("Q2", ["b"]),
            clarification("Q3", ["c"]),
        ])
        let m = model(fake)
        m.inputText = "ambiguous chest thing"
        await m.parse()
        if case .needsClarification = m.status {} else { XCTFail("round 1 should ask") }

        await m.replyToClarification("a")
        if case .needsClarification = m.status {} else { XCTFail("round 2 should still ask") }

        await m.replyToClarification("b")
        XCTAssertEqual(m.status, .declined, "after two clarification rounds without a draft, decline")
    }

    func testTypeItManuallyClearsClarificationAndKeepsInput() async {
        let m = model(FakeWorkoutParsing(clarification("Which one?", ["a"])))
        m.inputText = "did chest thing"
        await m.parse()
        guard case .needsClarification = m.status else { return XCTFail("expected a clarification") }

        m.typeItManually()
        XCTAssertEqual(m.status, .idle)
        XCTAssertEqual(m.inputText, "did chest thing", "the typed text is kept so the user can edit it")

        // A reply after bailing out is a no-op (clarification state was cleared).
        await m.replyToClarification("a")
        XCTAssertEqual(m.status, .idle)
    }

    func testNothingPersistsBeforeConfirm() async throws {
        let fake = FakeWorkoutParsing([clarification("Which one?", ["DB Bench Press"]), .draftFixture()])
        let m = model(fake)
        m.inputText = "did chest thing"
        await m.parse()
        XCTAssertEqual(try store.setCount(), 0, "a clarification writes nothing")

        await m.replyToClarification("DB Bench Press")
        XCTAssertEqual(try store.setCount(), 0, "an FM draft still writes nothing until the user confirms")

        m.save()
        XCTAssertEqual(try store.setCount(), 1, "only confirm/save persists")
    }

    func testFreshParseAfterClarificationResetsRoundState() async {
        // A clarification, then a brand-new entry that drafts — the new entry must
        // not inherit the prior round counter.
        let fake = FakeWorkoutParsing([clarification("Q1", ["a"]), .draftFixture(exercise: "Bench Press")])
        let m = model(fake)
        m.inputText = "ambiguous"
        await m.parse()
        guard case .needsClarification = m.status else { return XCTFail("expected clarification") }

        m.inputText = "bench press 135x8"
        await m.parse()   // second scripted outcome is a draft
        XCTAssertEqual(m.status, .idle)
        XCTAssertNotNil(m.pending)
    }

    func testStaleAsyncParseResultIsDropped() async {
        // Two parses overlap; the newer one completes first. When the older, slower
        // parse finally resolves it must be dropped, not allowed to overwrite the
        // newer pending state (the latest-request guard).
        let gated = GatedFakeParser()
        let m = model(gated)

        m.inputText = "first"
        let t1 = Task { await m.parse() }                 // generation 1
        while await gated.startedCount < 1 { await Task.yield() }

        m.inputText = "second"
        let t2 = Task { await m.parse() }                 // generation 2
        while await gated.startedCount < 2 { await Task.yield() }

        // Resolve the newer parse first → it applies.
        await gated.resume(at: 1, with: .draftFixture(exercise: "Second Lift"))
        await t2.value
        XCTAssertEqual(m.pendingExerciseName, "Second Lift")

        // Now resolve the older parse → it's stale and must be ignored.
        await gated.resume(at: 0, with: .draftFixture(exercise: "First Lift"))
        await t1.value
        XCTAssertEqual(m.pendingExerciseName, "Second Lift",
                       "the stale older parse result must not overwrite the newer one")
    }

    func testTypeItManuallyInvalidatesAnInFlightReply() async {
        // The user taps a reply, then bails with "Type it manually" before the slow
        // reply parse returns. The in-flight result must be dropped, not resurrect
        // the dismissed clarification/draft.
        let gated = GatedFakeParser()
        let m = model(gated)

        m.inputText = "did chest thing"
        let parseTask = Task { await m.parse() }
        while await gated.startedCount < 1 { await Task.yield() }
        await gated.resume(at: 0, with: clarification("Which one?", ["DB Bench Press"]))
        await parseTask.value
        guard case .needsClarification = m.status else { return XCTFail("expected a clarification") }

        let replyTask = Task { await m.replyToClarification("DB Bench Press") }
        while await gated.startedCount < 2 { await Task.yield() }
        XCTAssertTrue(m.isParsing, "a reply parse is in flight")

        m.typeItManually()
        XCTAssertEqual(m.status, .idle)
        XCTAssertFalse(m.isParsing)

        // The slow reply finally returns a draft — it must be ignored.
        await gated.resume(at: 1, with: .draftFixture())
        await replyTask.value
        XCTAssertEqual(m.status, .idle, "the dismissed flow stays dismissed")
        XCTAssertNil(m.pending, "a stale reply must not resurrect a draft after the user bailed")
    }

    func testFMDraftForUnknownExerciseStillShowsNewExerciseSuggestions() async {
        // An FM draft flows through the same PR-7 resolution as any other draft.
        let fake = FakeWorkoutParsing(.draftFixture(exercise: "bnch press"))
        let m = model(fake)
        m.inputText = "garbled bench"
        await m.parse()
        XCTAssertTrue(m.pendingCreatesNewExercise)
        XCTAssertFalse(m.pendingSuggestions.isEmpty, "PR-7 'did you mean' suggestions surface for an FM-proposed new lift")
    }
}
