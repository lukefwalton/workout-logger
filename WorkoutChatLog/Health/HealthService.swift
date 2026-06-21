import Foundation

/// On-device Apple Health access, behind a protocol so **no HealthKit symbol leaks
/// into code that must compile or test without the entitlement** — the widget
/// process (PR 12), the Linux CI, and the unit tests. The real implementation
/// (`HealthKitService`) lives entirely inside `#if canImport(HealthKit)`; tests and
/// non-HealthKit builds use a fake or `NoopHealthService`.
///
/// Doctrine (§1): HealthKit is opt-in and the app is fully functional without it.
/// We read bodyweight (for the PR 11 estimate and bodyweight-relative PRs) and write
/// **one** strength workout per *finished session* — never the estimated calorie
/// number into energy data, which is exactly what App Review flags.
protocol HealthService {
    /// Whether Health data exists on this device/build at all (false on iPad, Linux,
    /// or a non-HealthKit build).
    var isHealthDataAvailable: Bool { get }

    /// Request read(`bodyMass`) + share(`workout`) authorization, then report whether
    /// **workout sharing** is actually authorized. Share status is queryable (unlike
    /// read status, which HealthKit hides), so this is the signal the Settings toggle
    /// uses to reconcile a denial. False also covers Health-unavailable / request error.
    func requestAuthorization() async -> Bool

    /// The most recent recorded bodyweight in **kilograms**, or nil when there's no
    /// sample / Health is unavailable / read wasn't granted. Never invents a value.
    func latestBodyweightKilograms() async -> Double?

    /// Write one `.traditionalStrengthTraining` workout spanning `[start, end]`.
    /// Returns whether a workout was actually written — false when Health is
    /// unavailable, sharing isn't authorized, or the bounds are degenerate
    /// (`end <= start`). Writes **no** energy or distance samples.
    func saveStrengthWorkout(start: Date, end: Date) async -> Bool
}

/// The stand-in used when HealthKit isn't compiled in (Linux/CI) or the device has
/// no Health data: everything is unavailable, so the app falls back to the manual
/// bodyweight field and simply never writes workouts.
struct NoopHealthService: HealthService {
    var isHealthDataAvailable: Bool { false }
    func requestAuthorization() async -> Bool { false }
    func latestBodyweightKilograms() async -> Double? { nil }
    func saveStrengthWorkout(start: Date, end: Date) async -> Bool { false }
}

/// Picks the real service when the SDK is present, the no-op otherwise. The `#if`
/// is the only place the two worlds meet; callers just get a `HealthService`.
enum HealthServiceFactory {
    static func make() -> HealthService {
        #if canImport(HealthKit)
        return HealthKitService()
        #else
        return NoopHealthService()
        #endif
    }
}

/// Keys shared by `SettingsView` (`@AppStorage`) and the finish flow so the toggle
/// and the manual bodyweight read/write the *same* defaults.
enum HealthPreferences {
    /// "Save workouts to Apple Health" — **user intent**, default off. System write
    /// permission is not the same as the user asking us to write.
    static let saveWorkoutsToHealthKey = "settings.health.saveWorkoutsToAppleHealth"
    /// Manual bodyweight in **kilograms**, used when HealthKit bodyweight is absent.
    static let manualBodyweightKgKey = "settings.health.manualBodyweightKg"
}

/// Applies both gates before anything touches Health: the user's "Save workouts"
/// toggle (**intent**) and the service's own availability/authorization checks
/// (**capability**). Holds a `HealthService` so `TodayModel` stays
/// HealthKit-symbol-free, and reads the toggle / manual weight from injectable
/// `UserDefaults` for testability.
struct HealthWorkoutCoordinator {
    let service: HealthService
    let defaults: UserDefaults

    init(service: HealthService = HealthServiceFactory.make(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    var isSavingWorkoutsEnabled: Bool {
        defaults.bool(forKey: HealthPreferences.saveWorkoutsToHealthKey)
    }

    /// Best-effort write of one workout for a just-finished session — but only when
    /// the user enabled the toggle. The service still no-ops if it isn't authorized
    /// or the bounds are degenerate. Returns whether a workout was written.
    @discardableResult
    func recordFinishedSession(start: Date, end: Date) async -> Bool {
        guard isSavingWorkoutsEnabled else { return false }
        return await service.saveStrengthWorkout(start: start, end: end)
    }

    /// Bodyweight in kilograms: HealthKit's latest if available, else the manual
    /// Settings value, else nil (PR 11 then shows "add your bodyweight"). Never
    /// fabricates a number.
    func bodyweightKilograms() async -> Double? {
        if let healthKit = await service.latestBodyweightKilograms() { return healthKit }
        let manual = defaults.double(forKey: HealthPreferences.manualBodyweightKgKey)
        return manual > 0 ? manual : nil
    }

    /// Ask the system for authorization — called when the user flips the toggle on.
    @discardableResult
    func requestAuthorization() async -> Bool {
        await service.requestAuthorization()
    }
}
