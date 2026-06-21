import Foundation
@testable import WorkoutChatLog

/// A scripted `HealthService` for the PR 10 tests — never imports HealthKit. Models
/// the two real gates: `available` (is Health usable on this device/build) and
/// `authorized` (did the user grant write access). A workout is "written" only when
/// both hold and the bounds are sane, mirroring `HealthKitService`.
///
/// **Failure modes mirror the real `HKWorkoutBuilder` flow.** Real
/// `HealthKitService.saveStrengthWorkout` runs three steps after the gate:
/// `beginCollection(at:)`, `endCollection(at:)`, `finishWorkout()` — each of which
/// can throw (or return nil). Tests opt into a stage failure via the `shouldFail…`
/// flags so the silent-swallow in `TodayModel.pendingHealthWrite` is covered for
/// each path that returns false.
final class FakeHealthService: HealthService {
    var available = true
    var authorized = true
    var bodyweightKg: Double?

    var shouldFailBeginCollection = false
    var shouldFailEndCollection = false
    var shouldFailFinishWorkout = false

    private(set) var workoutWrites = 0
    private(set) var authorizationRequests = 0
    private(set) var lastWorkoutBounds: (start: Date, end: Date)?

    var isHealthDataAvailable: Bool { available }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return available && authorized
    }

    func latestBodyweightKilograms() async -> Double? {
        available ? bodyweightKg : nil
    }

    func saveStrengthWorkout(start: Date, end: Date) async -> Bool {
        guard available, authorized, end > start else { return false }
        // Stage order mirrors HealthKitService.saveStrengthWorkout's builder calls; any
        // throw before finishWorkout returns false without bumping workoutWrites.
        if shouldFailBeginCollection { return false }
        if shouldFailEndCollection { return false }
        if shouldFailFinishWorkout { return false }
        workoutWrites += 1
        lastWorkoutBounds = (start, end)
        return true
    }
}
