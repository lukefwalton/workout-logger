import XCTest
@testable import WorkoutChatLog

/// Pure, deterministic calorie logic — duration precedence, the formula, and the
/// clamps. No store, no UI.
final class CalorieEstimateTests: XCTestCase {

    private let policy = CaloriePolicy.default   // MET 5, cap 6h, single-set 10min
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func ended(after seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: - Duration precedence (explicit > set-span > manual > none)

    func testExplicitBoundsWinOverEverything() {
        let duration = CalorieEstimate.resolveDuration(startedAt: start, endedAt: ended(after: 90 * 60),
                                                       setSpanSeconds: 9_999, manualSeconds: 60 * 60, policy: policy)
        XCTAssertEqual(duration, .init(hours: 1.5, source: .explicitBounds))
    }

    func testSetSpanUsedWhenNoExplicitEnd() {
        let duration = CalorieEstimate.resolveDuration(startedAt: start, endedAt: nil,
                                                       setSpanSeconds: 45 * 60, manualSeconds: 30 * 60, policy: policy)
        XCTAssertEqual(duration, .init(hours: 0.75, source: .setSpan))
    }

    func testManualUsedOnlyWhenNoBoundsOrSpan() {
        let duration = CalorieEstimate.resolveDuration(startedAt: start, endedAt: nil,
                                                       setSpanSeconds: nil, manualSeconds: 30 * 60, policy: policy)
        XCTAssertEqual(duration, .init(hours: 0.5, source: .manual))
    }

    func testNoInputsYieldsNoDuration() {
        XCTAssertNil(CalorieEstimate.resolveDuration(startedAt: start, endedAt: nil,
                                                     setSpanSeconds: nil, manualSeconds: nil, policy: policy))
    }

    func testSingleSetZeroSpanUsesSmallFallback() throws {
        let duration = CalorieEstimate.resolveDuration(startedAt: start, endedAt: nil,
                                                       setSpanSeconds: 0, manualSeconds: nil, policy: policy)
        XCTAssertEqual(try XCTUnwrap(duration?.hours), 10.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(duration?.source, .setSpan)
    }

    func testAbsurdGapIsClampedToMax() {
        let duration = CalorieEstimate.resolveDuration(startedAt: start, endedAt: ended(after: 50 * 3600),
                                                       setSpanSeconds: nil, manualSeconds: nil, policy: policy)
        XCTAssertEqual(duration?.hours, 6.0, "capped at maxSessionHours")
    }

    func testNonPositiveExplicitBoundsFallThrough() {
        // ended == started (or before) is not a usable explicit duration → set-span.
        let duration = CalorieEstimate.resolveDuration(startedAt: start, endedAt: start,
                                                       setSpanSeconds: 20 * 60, manualSeconds: nil, policy: policy)
        XCTAssertEqual(duration?.source, .setSpan)
    }

    // MARK: - Formula + outcomes

    func testFormulaMatchesFixture() {
        XCTAssertEqual(CalorieEstimate.kcal(bodyweightKg: 80, durationHours: 1.5, met: 5.0), 600, accuracy: 1e-9)
    }

    func testEstimateProducesRoundedKcal() {
        let outcome = CalorieEstimate.estimate(startedAt: start, endedAt: ended(after: 90 * 60),
                                               setSpanSeconds: nil, manualSeconds: nil,
                                               bodyweightKg: 80, policy: policy)
        XCTAssertEqual(outcome, .kcal(600, .explicitBounds))
    }

    func testMissingBodyweightPromptsNotZero() {
        let outcome = CalorieEstimate.estimate(startedAt: start, endedAt: ended(after: 3600),
                                               setSpanSeconds: nil, manualSeconds: nil,
                                               bodyweightKg: nil, policy: policy)
        XCTAssertEqual(outcome, .needsBodyweight)
    }

    func testMissingDurationPromptsNotZero() {
        let outcome = CalorieEstimate.estimate(startedAt: start, endedAt: nil,
                                               setSpanSeconds: nil, manualSeconds: nil,
                                               bodyweightKg: 80, policy: policy)
        XCTAssertEqual(outcome, .needsDuration)
    }

    func testUnparseableStartFallsToSetSpanNotFakedBounds() {
        // A missing/unparseable start disqualifies explicit bounds; the set-span tier
        // (30 min) is used instead of inventing a duration from a fake start.
        let outcome = CalorieEstimate.estimate(startedAt: nil, endedAt: ended(after: 3600),
                                               setSpanSeconds: 30 * 60, manualSeconds: nil,
                                               bodyweightKg: 80, policy: policy)
        XCTAssertEqual(outcome, .kcal(200, .setSpan))   // 5 × 80 × 0.5
    }

    func testUnparseableStartWithNoSpanCannotUseExplicitBounds() {
        let outcome = CalorieEstimate.estimate(startedAt: nil, endedAt: ended(after: 3600),
                                               setSpanSeconds: nil, manualSeconds: nil,
                                               bodyweightKg: 80, policy: policy)
        XCTAssertEqual(outcome, .needsDuration, "no start → explicit bounds unusable; nothing fabricated")
    }

    func testZeroBodyweightIsTreatedAsMissing() {
        let outcome = CalorieEstimate.estimate(startedAt: start, endedAt: ended(after: 3600),
                                               setSpanSeconds: nil, manualSeconds: nil,
                                               bodyweightKg: 0, policy: policy)
        XCTAssertEqual(outcome, .needsBodyweight, "never multiply by a fake 0 bodyweight")
    }
}

/// Integration: History attaches the estimate from real session data + the injected
/// bodyweight. Timing-independent — asserts the *kind* of outcome, not an exact kcal
/// that would depend on sub-second set timestamps.
@MainActor
final class HistoryCalorieTests: XCTestCase {

    private var path: String!
    private var store: WorkoutStore!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "wcl-hist-cal-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: path))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: [
            SetDraft(exerciseName: "Bench Press", weight: 135, unit: .lb, loadKind: .external, reps: 8)
        ]))
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func testSessionGetsAKcalEstimateWhenBodyweightKnown() async {
        let model = HistoryModel(store: store, bodyweightKg: { 80 })
        await model.load()
        guard case .loaded(let sections) = model.state, let section = sections.first else {
            return XCTFail("expected a loaded section")
        }
        if case .kcal(let value, _) = section.calorie {
            XCTAssertGreaterThanOrEqual(value, 0)
        } else {
            XCTFail("a session with sets + bodyweight should estimate kcal, got \(section.calorie)")
        }
    }

    func testSessionPromptsForBodyweightWhenMissing() async {
        let model = HistoryModel(store: store, bodyweightKg: { nil })
        await model.load()
        guard case .loaded(let sections) = model.state, let section = sections.first else {
            return XCTFail("expected a loaded section")
        }
        XCTAssertEqual(section.calorie, .needsBodyweight)
    }

    func testSessionSetSpansReturnsAnEntryPerSession() throws {
        let spans = try store.sessionSetSpans()
        XCTAssertEqual(spans.count, 1)
        XCTAssertGreaterThanOrEqual(spans.values.first ?? -1, 0)
    }
}
