import Foundation

/// Realistic bench-press history for screenshots and local demos. Writes through
/// `WorkoutStore` so charts match production analytics.
enum DemoProgressSeeder {
    @MainActor
    static func seedBenchProgress(store: WorkoutStore) throws {
        let sessions: [(daysAgo: Int, weight: Double, reps: Int)] = [
            (56, 185, 8),
            (49, 195, 8),
            (42, 205, 5),
            (35, 215, 5),
            (28, 225, 5),
            (21, 225, 8),
            (14, 235, 5),
            (7, 245, 5),
        ]
        let calendar = Calendar.current
        let now = Date()
        for session in sessions {
            guard let startedAt = calendar.date(byAdding: .day, value: -session.daysAgo, to: now) else { continue }
            let draft = WorkoutDraft(
                startedAt: startedAt,
                name: "Push",
                notes: nil,
                sets: [
                    SetDraft(
                        exerciseName: "Bench Press",
                        weight: session.weight,
                        unit: .lb,
                        loadKind: .external,
                        reps: session.reps,
                        rir: 2,
                        setType: .working,
                        notes: nil
                    )
                ]
            )
            let result = try store.save(draft)
            try store.finishSession(result.sessionID, endedAt: startedAt.addingTimeInterval(3600),
                                    name: draft.name, notes: nil, feel: nil, isDeload: false)
        }
    }
}
