import Foundation

/// JSON-on-UserDefaults persistence for the Today tab's plan state: the user's
/// `SavedPlan` library and the currently-active plan scaffold. Pure I/O —
/// `TodayModel` owns the @Published mirrors and reentrancy guard
/// (`isRestoringPlanState`) and only delegates encode/decode here.
///
/// Keys are versioned (`.v1`) so an on-disk format change can ship a new key
/// instead of silently breaking older installs.
struct PlanStore {
    static let savedPlansKey = "TodayModel.savedPlans.v1"
    static let activePlanKey = "TodayModel.activePlan.v1"

    let defaults: UserDefaults

    /// The on-disk shape of the active plan. Held here (not on `TodayModel`)
    /// because it only exists as the serialization vehicle — `TodayModel`
    /// already has the same fields as @Published properties.
    struct ActivePlanScaffold: Codable, Equatable {
        var mode: TodayModel.Mode
        var planName: String
        var planText: String
        var selectedSavedPlanID: UUID?
        var plannedExercises: [TodayModel.PlannedExercise]
        var selectedPlannedExerciseID: UUID?
    }

    func loadSavedPlans() -> [TodayModel.SavedPlan]? {
        guard let data = defaults.data(forKey: Self.savedPlansKey),
              let decoded = try? JSONDecoder().decode([TodayModel.SavedPlan].self, from: data) else {
            return nil
        }
        return decoded
    }

    func loadActivePlanScaffold() -> ActivePlanScaffold? {
        guard let data = defaults.data(forKey: Self.activePlanKey),
              let decoded = try? JSONDecoder().decode(ActivePlanScaffold.self, from: data) else {
            return nil
        }
        return decoded
    }

    func saveSavedPlans(_ plans: [TodayModel.SavedPlan]) {
        guard let data = try? JSONEncoder().encode(plans) else { return }
        defaults.set(data, forKey: Self.savedPlansKey)
    }

    func saveActivePlanScaffold(_ scaffold: ActivePlanScaffold) {
        guard let data = try? JSONEncoder().encode(scaffold) else { return }
        defaults.set(data, forKey: Self.activePlanKey)
    }
}
