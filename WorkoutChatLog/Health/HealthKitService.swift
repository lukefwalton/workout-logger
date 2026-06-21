#if canImport(HealthKit)
import Foundation
import HealthKit
import os

/// The real `HealthService`, entirely inside `#if canImport(HealthKit)` so not one
/// HealthKit symbol reaches always-compiled code. Reads the latest bodyweight and
/// writes one strength workout per finished session — **no energy/distance samples**
/// (the calorie estimate stays in-app; a guessed number polluting the Move ring is
/// what App Review flags).
///
/// NOT COMPILED HERE (Linux, no HealthKit SDK). The symbol names below
/// (`HKQuantityType(.bodyMass)`, `HKWorkoutBuilder`, `.traditionalStrengthTraining`)
/// are from the spec and must be verified against the installed SDK in Xcode.
final class HealthKitService: HealthService {
    private let store = HKHealthStore()
    /// Release-safe diagnostics: failures here are silent to the user (the feature
    /// just no-ops), so log them to the unified log — visible in Console/`log` on a
    /// device, not only under a DEBUG `print`. An `HKError` carries no health values,
    /// so the description is safe to log `.public`.
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "WorkoutChatLog",
                             category: "HealthKit")

    private var bodyMassType: HKQuantityType { HKQuantityType(.bodyMass) }
    private var workoutType: HKObjectType { HKObjectType.workoutType() }

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async -> Bool {
        guard isHealthDataAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()],
                                                 read: [bodyMassType])
            // Report whether we can actually *write workouts* now — share status is
            // queryable (unlike read status, which HealthKit hides). This lets the
            // Settings toggle reconcile a workout-sharing denial instead of reading
            // "on" for a feature that will silently no-op.
            return store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        } catch {
            log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func latestBodyweightKilograms() async -> Double? {
        guard isHealthDataAvailable else { return nil }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: bodyMassType,
                                      predicate: nil,
                                      limit: 1,
                                      sortDescriptors: [sort]) { [log] _, samples, error in
                if let error {
                    // A real query failure is distinct from "no bodyweight recorded";
                    // log it so an ignored Health weight is diagnosable on device.
                    log.error("bodyweight query failed: \(error.localizedDescription, privacy: .public)")
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: sample.quantity.doubleValue(for: .gramUnit(with: .kilo)))
            }
            store.execute(query)
        }
    }

    func saveStrengthWorkout(start: Date, end: Date) async -> Bool {
        guard isHealthDataAvailable, end > start else { return false }
        // System write permission (intent is gated upstream by the Settings toggle).
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            return false
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: start)
            try await builder.endCollection(at: end)
            // finishWorkout() returns the saved HKWorkout (or nil). No samples were
            // added, so the session is recorded with its time bounds and nothing else.
            let workout = try await builder.finishWorkout()
            return workout != nil
        } catch {
            log.error("workout write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
#endif
