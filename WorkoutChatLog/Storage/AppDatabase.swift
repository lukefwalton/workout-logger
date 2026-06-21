import Foundation

/// Composition root for the on-device database (the **write** side). Opens the
/// SQLite file from the shared App Group container — so a second process (the
/// widget, PR 12) can open the exact same file — migrates the schema, and seeds the
/// canonical exercise library on first launch. The whole app holds exactly one of
/// these. The container/path resolution lives in `SharedDatabase` so the read-only
/// widget can find the same file without linking this write path.
enum AppDatabase {
    // @MainActor because it drives the mutating store APIs (migrate, seed), which
    // carry the single-connection write invariant (§1). Called from the app's
    // launch task, which is already main-actor isolated.
    @MainActor
    static func makeStore() throws -> WorkoutStore {
        let store = WorkoutStore(db: try SQLiteDB(path: SharedDatabase.databaseURL().path))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load())
        try store.seedSupplementsIfNeeded()
        return store
    }
}
