import XCTest
@testable import WorkoutChatLog

/// PR 10 integration: finishing a workout in `TodayModel` mirrors exactly one
/// session to Apple Health when the user opted in, and nothing when they didn't —
/// driven by a fake `HealthService`. The fire-and-forget Health write is awaited via
/// the model's `pendingHealthWrite` handle so the assertions are deterministic.
@MainActor
final class TodayModelHealthTests: XCTestCase {

    private var path: String!
    private var store: WorkoutStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "wcl-today-health-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: path))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
        suiteName = "wcl-today-health-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        store = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func makeModel(savingEnabled: Bool, service: FakeHealthService) -> TodayModel {
        if savingEnabled { defaults.set(true, forKey: HealthPreferences.saveWorkoutsToHealthKey) }
        let coordinator = HealthWorkoutCoordinator(service: service, defaults: defaults)
        return TodayModel(store: store, planDefaults: defaults, health: coordinator)
    }

    private func logSet(_ model: TodayModel, _ text: String) async {
        model.inputText = text
        await model.parse()   // parse() is async since PR 8 (deterministic → FM)
        model.save()
    }

    func testFinishingWritesExactlyOneWorkoutWhenEnabled() async throws {
        let service = FakeHealthService()
        let model = makeModel(savingEnabled: true, service: service)

        await logSet(model, "bench 135x8")
        model.finishWorkout(feel: .solid, isDeload: false, notes: nil)
        await model.pendingHealthWrite?.value

        XCTAssertEqual(service.workoutWrites, 1, "one HKWorkout per finished session, not per set")
        let bounds = try XCTUnwrap(service.lastWorkoutBounds)
        XCTAssertLessThan(bounds.start, bounds.end, "the workout spans the session's bounds")
    }

    func testFinishingWritesNothingWhenToggleOff() async {
        let service = FakeHealthService()
        let model = makeModel(savingEnabled: false, service: service)

        await logSet(model, "bench 135x8")
        model.finishWorkout(feel: nil, isDeload: false, notes: nil)
        await model.pendingHealthWrite?.value

        XCTAssertEqual(service.workoutWrites, 0, "default-off toggle writes nothing even with permission")
    }

    func testFinishingWritesNothingWhenPermissionDenied() async {
        let service = FakeHealthService()
        service.authorized = false
        let model = makeModel(savingEnabled: true, service: service)

        await logSet(model, "bench 135x8")
        model.finishWorkout(feel: nil, isDeload: false, notes: nil)
        await model.pendingHealthWrite?.value

        XCTAssertEqual(service.workoutWrites, 0, "no write when the user hasn't granted HealthKit permission")
    }

    // MARK: - Builder-stage failure swallowing
    // Real HealthKitService.saveStrengthWorkout chains beginCollection → endCollection →
    // finishWorkout, each of which can throw. The model's pendingHealthWrite is
    // fire-and-forget and silently no-ops on a `false` return — these three tests pin
    // that swallow behavior for each builder stage so a future change can't accidentally
    // start crashing the finish flow when Health is misbehaving.

    func testFinishingSwallowsBeginCollectionFailure() async {
        let service = FakeHealthService()
        service.shouldFailBeginCollection = true
        let model = makeModel(savingEnabled: true, service: service)

        await logSet(model, "bench 135x8")
        model.finishWorkout(feel: nil, isDeload: false, notes: nil)
        await model.pendingHealthWrite?.value

        XCTAssertEqual(service.workoutWrites, 0, "beginCollection failure aborts the write")
    }

    func testFinishingSwallowsEndCollectionFailure() async {
        let service = FakeHealthService()
        service.shouldFailEndCollection = true
        let model = makeModel(savingEnabled: true, service: service)

        await logSet(model, "bench 135x8")
        model.finishWorkout(feel: nil, isDeload: false, notes: nil)
        await model.pendingHealthWrite?.value

        XCTAssertEqual(service.workoutWrites, 0, "endCollection failure aborts the write")
    }

    func testFinishingSwallowsFinishWorkoutFailure() async {
        let service = FakeHealthService()
        service.shouldFailFinishWorkout = true
        let model = makeModel(savingEnabled: true, service: service)

        await logSet(model, "bench 135x8")
        model.finishWorkout(feel: nil, isDeload: false, notes: nil)
        await model.pendingHealthWrite?.value

        XCTAssertEqual(service.workoutWrites, 0, "finishWorkout failure aborts the write")
    }
}
