import Foundation

/// State behind the Progress tab. Loads the set history once, exposes the
/// exercise picker + the exclude-off-days/deloads toggle, and computes each
/// series on demand through `ProgressAnalytics` (deterministic; canonical-only).
@MainActor
final class ProgressModel: ObservableObject {
    enum State: Equatable {
        case loading
        case empty
        case loaded
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var exercises: [ProgressAnalytics.ExerciseOption] = []
    @Published var selectedExerciseID: Int64?
    /// One surfaced toggle (default on) — excluded sessions drop from trend math
    /// only, never from History.
    @Published var excludeNonRepresentative = AnalyticsPolicy.default.excludeOffDays

    private var rows: [WorkoutSetHistoryRow] = []
    private let store: WorkoutStore

    /// Monotonic load-request token — same race guard as `HistoryModel.load`.
    /// A slow earlier `load()` must not overwrite a newer one's result; tests
    /// triggering two refreshes back-to-back are the realistic case.
    private var loadGeneration = 0

    init(store: WorkoutStore) { self.store = store }

    /// The policy reflects the toggle; the same switch drives off-day and deload
    /// exclusion so "show everything" is one tap.
    private var policy: AnalyticsPolicy {
        var policy = AnalyticsPolicy.default
        policy.excludeOffDays = excludeNonRepresentative
        policy.excludeDeloadSessions = excludeNonRepresentative
        return policy
    }

    /// Reload progress data. The SQL read + the exercise rollup move off the
    /// main thread on a `Task.detached`; only the final state commit is on main.
    /// Matches the jank fix in `HistoryModel.load()` — heavy reads on the main
    /// thread were the same pattern noted in the portfolio audit.
    ///
    /// The class is `@MainActor`, so the state assignments after the `await`
    /// resume on the main actor. The `loadGeneration` token drops any result
    /// from an older request that resolves after a newer one.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let store = self.store
        do {
            let result = try await Task.detached(priority: .userInitiated) { () throws -> (rows: [WorkoutSetHistoryRow], exercises: [ProgressAnalytics.ExerciseOption]) in
                let rows = try store.setHistory(since: nil, includeNotes: false)
                let exercises = rows.isEmpty ? [] : ProgressAnalytics.exercises(rows)
                return (rows, exercises)
            }.value
            guard generation == loadGeneration else { return }
            rows = result.rows
            guard !rows.isEmpty else { state = .empty; exercises = []; return }
            exercises = result.exercises
            if selectedExerciseID == nil || !exercises.contains(where: { $0.id == selectedExerciseID }) {
                selectedExerciseID = exercises.first?.id
            }
            state = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed("Couldn't load your progress.")
        }
    }

    var selectedExercise: ProgressAnalytics.ExerciseOption? {
        exercises.first { $0.id == selectedExerciseID }
    }

    func e1RMSeries() -> [ProgressAnalytics.SessionValue] {
        selectedExerciseID.map { ProgressAnalytics.e1RMSeries(rows, exerciseID: $0, policy: policy) } ?? []
    }
    func volumeSeries() -> [ProgressAnalytics.SessionValue] {
        selectedExerciseID.map { ProgressAnalytics.volumeSeries(rows, exerciseID: $0, policy: policy) } ?? []
    }
    func repsSeries() -> [ProgressAnalytics.SessionValue] {
        selectedExerciseID.map { ProgressAnalytics.repsSeries(rows, exerciseID: $0, policy: policy) } ?? []
    }
    func muscleWeeklyHardSets() -> [ProgressAnalytics.MuscleWeekCount] {
        ProgressAnalytics.muscleWeeklyHardSets(rows, policy: policy)
    }
}
