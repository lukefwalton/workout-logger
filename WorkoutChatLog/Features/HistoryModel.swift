import Foundation

/// State + logic behind the History tab: a session-grouped, set-by-set audit of
/// what was actually saved, with delete and edit. Kept separate from the view so
/// grouping, sorting, and the delete/edit outcomes are unit-testable without a
/// running UI. Reads go through `WorkoutStore.setHistory`; every mutation goes
/// through a dedicated `@MainActor` store API — no SQL here.
@MainActor
final class HistoryModel: ObservableObject {

    /// One workout: a contiguous run of `setHistory` rows sharing a session id,
    /// already in set-index order.
    struct Section: Identifiable, Equatable {
        let id: Int64                 // session id
        var rows: [WorkoutSetHistoryRow]
        let name: String?
        let notes: String?
        let startedAt: String
        let endedAt: String?
        let feel: SessionFeel?
        let isDeload: Bool
        /// Rough per-session kcal estimate (PR 11), filled in `load` once bodyweight
        /// and the set-time span are known. Defaults to the "no duration" prompt.
        var calorie: CalorieEstimate.Outcome = .needsDuration

        var setCount: Int { rows.count }
        var title: String {
            if let name, !name.isEmpty { return name }
            return HistoryModel.displayDate(startedAt)
        }
    }

    enum State: Equatable {
        case loading
        case loaded([Section])
        case empty
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    /// Logged cardio bouts, newest first — shown in their own History section.
    /// Cardio is stored independently of strength sessions, so it rides alongside
    /// the session sections rather than inside them.
    @Published private(set) var cardio: [CardioEntry] = []
    private let store: WorkoutStore
    private let policy: CaloriePolicy
    /// Manual bodyweight (kg) for the calorie estimate; injected for tests. Defaults
    /// to the shared Settings value (nil when unset → the "add your bodyweight" prompt).
    private let bodyweightKg: () -> Double?

    /// Monotonic load-request token. The async path can have two `load()`s in
    /// flight (e.g. `.task` and a post-mutation reload), so a slow earlier one
    /// must not overwrite a newer one's result. The same `parseGeneration` idea
    /// used in `TodayModel.runParse`. Mutated and read on the main actor (this
    /// class is `@MainActor`), so the check is race-free.
    private var loadGeneration = 0

    /// The most recent fire-and-forget reload spawned by a `mutate`/`attempt`,
    /// exposed so callers (and tests) can `await` it when they need a known
    /// "post-mutation state is current" point. Production code reads it
    /// transparently via SwiftUI's `@Published` republish chain.
    private(set) var pendingReload: Task<Void, Never>?

    init(store: WorkoutStore,
         policy: CaloriePolicy = .default,
         bodyweightKg: @escaping () -> Double? = {
             let value = UserDefaults.standard.double(forKey: CaloriePreferences.bodyweightKgKey)
             return value > 0 ? value : nil
         }) {
        self.store = store
        self.policy = policy
        self.bodyweightKg = bodyweightKg
    }

    /// Reload history. The SQL + grouping pass moves off the main thread on a
    /// `Task.detached` (SQLite is opened with FULLMUTEX, so concurrent reads are
    /// safe); only the final state commit happens on main. Avoids the
    /// "scrolling-frequency jank after a year of data" risk noted in the
    /// portfolio audit. Tests can `await model.load()` to drive the same path.
    ///
    /// The class is `@MainActor`, so the `state = …` assignment after the
    /// `await` resumes on the main actor — Swift Concurrency preserves the
    /// caller's actor across suspension. A `loadGeneration` token then drops
    /// any result from an older request that resolves after a newer one.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let bodyweight = bodyweightKg()
        let currentPolicy = policy
        let store = self.store
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                () throws -> (sections: [Section], cardio: [CardioEntry]?) in
                let rows = try store.setHistory(since: nil, includeNotes: true)
                let spans: [Int64: Double]
                do {
                    spans = try store.sessionSetSpans()
                } catch {
                    // A span-query failure degrades the estimate to a prompt, but
                    // surface it in DEBUG so it stays distinguishable from
                    // genuinely missing duration data.
                    #if DEBUG
                    print("[HistoryModel] sessionSetSpans failed: \(error)")
                    #endif
                    spans = [:]
                }
                let sections = Self.computeSections(rows: rows, spans: spans,
                                                    bodyweightKg: bodyweight, policy: currentPolicy)
                // nil signals a cardio read failure (distinct from "no cardio"),
                // so the caller can surface it rather than silently show empty.
                let cardio: [CardioEntry]?
                do {
                    cardio = try store.cardioEntries()
                } catch {
                    #if DEBUG
                    print("[HistoryModel] cardioEntries failed: \(error)")
                    #endif
                    cardio = nil
                }
                return (sections, cardio)
            }.value
            // A newer `load()` has run since this one started — drop the stale
            // result rather than overwrite the fresher state.
            guard generation == loadGeneration else { return }
            if let loadedCardio = result.cardio {
                cardio = loadedCardio
                // History is empty only when there's neither a strength session nor
                // a cardio bout; cardio-only days still render.
                state = (result.sections.isEmpty && loadedCardio.isEmpty) ? .empty : .loaded(result.sections)
            } else {
                // Cardio read failed: keep showing strength if there is any, but a
                // cardio-only user sees a load failure instead of a misleading empty.
                cardio = []
                state = result.sections.isEmpty ? .failed("Couldn't load your history.") : .loaded(result.sections)
            }
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed("Couldn't load your history.")
        }
    }

    /// Pure grouping + calorie attachment, runnable from any thread — kept here
    /// (not on the model) so the background task doesn't capture `self` and the
    /// expensive per-section work can move off main without re-entering the
    /// main actor. Deterministic; never invents a number.
    nonisolated private static func computeSections(rows: [WorkoutSetHistoryRow],
                                         spans: [Int64: Double],
                                         bodyweightKg: Double?,
                                         policy: CaloriePolicy) -> [Section] {
        var sections = group(rows)
        for index in sections.indices {
            let section = sections[index]
            // An unparseable start disqualifies the explicit-bounds tier (the set-span
            // tier still applies); never substitute `Date()`, which would invent a
            // duration and make the estimate non-deterministic.
            let started = WorkoutStore.date(section.startedAt)
            let ended = section.endedAt.flatMap { WorkoutStore.date($0) }
            sections[index].calorie = CalorieEstimate.estimate(
                startedAt: started, endedAt: ended,
                setSpanSeconds: spans[section.id], manualSeconds: nil,
                bodyweightKg: bodyweightKg, policy: policy)
        }
        return sections
    }

    func deleteSet(_ id: Int64) { mutate { try store.deleteSet(id) } }
    func deleteSession(_ id: Int64) { mutate { try store.deleteSession(id) } }
    func deleteCardio(_ id: Int64) { mutate { try store.deleteCardioEntry(id) } }

    /// Returns an error message to show in the editor on rejection, or nil on
    /// success (after reloading).
    func updateSet(_ id: Int64, exerciseName: String, weight: Double, unit: WeightUnit,
                   loadKind: WorkoutLoadKind, reps: Int, rir: Int?, setType: SetType, notes: String?) -> String? {
        attempt {
            try store.updateSet(id, exerciseName: exerciseName, weight: weight, unit: unit,
                                loadKind: loadKind, reps: reps, rir: rir, setType: setType, notes: notes)
        }
    }

    func updateSession(_ id: Int64, name: String?, startedAt: Date?, endedAt: Date?,
                       notes: String?, feel: SessionFeel?, isDeload: Bool) -> String? {
        attempt {
            try store.updateSession(id, name: name, startedAt: startedAt, endedAt: endedAt,
                                    notes: notes, feel: feel, isDeload: isDeload)
        }
    }

    /// Fire-and-reload for deletes. On failure, surface it and do **not** reload —
    /// a reload would overwrite the error with a successful read and make a
    /// rejected delete look like it silently did nothing.
    ///
    /// The reload is a `Task { await load() }` so the caller doesn't block; it's
    /// retained in `pendingReload` so tests (and any caller that needs a known
    /// "state-is-current" point) can `await model.pendingReload?.value`.
    private func mutate(_ action: () throws -> Void) {
        do {
            try action()
            pendingReload = Task { [weak self] in await self?.load() }
        } catch {
            state = .failed(message(for: error))
        }
    }

    /// Edits can be rejected (validation); surface the message and only reload on
    /// success so the editor can stay open on failure.
    private func attempt(_ action: () throws -> Void) -> String? {
        do {
            try action()
            pendingReload = Task { [weak self] in await self?.load() }
            return nil
        } catch {
            return message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        if let storeError = error as? WorkoutStoreError { return storeError.description }
        return TodayModel.message(for: error)   // friendly for ParseError, generic otherwise
    }

    /// Group rows into one section per session, in first-appearance order. Keyed
    /// by session id rather than assuming contiguous rows, so two sessions sharing
    /// a `started_at` can't split into duplicate sections even if their rows ever
    /// interleave. (`setHistory` already sorts by `ws.id` then `set_index`, so
    /// sections come out newest-first with rows in order.)
    nonisolated static func group(_ rows: [WorkoutSetHistoryRow]) -> [Section] {
        var sections: [Section] = []
        var indexByID: [Int64: Int] = [:]
        for row in rows {
            if let index = indexByID[row.sessionID] {
                sections[index].rows.append(row)
            } else {
                indexByID[row.sessionID] = sections.count
                sections.append(Section(id: row.sessionID, rows: [row], name: row.sessionName,
                                        notes: row.sessionNotes, startedAt: row.startedAt,
                                        endedAt: row.sessionEndedAt, feel: row.sessionFeel,
                                        isDeload: row.sessionIsDeload))
            }
        }
        return sections
    }

    /// Format an ISO timestamp for History rows using Swift's value-style
    /// `Date.formatted(date:time:)` API for the display string. Parsing goes
    /// through the canonical `WorkoutDateFormat` shared with the store and the
    /// widget — `ISO8601DateFormatter` is documented thread-safe so a single
    /// process-wide instance is correct (the prior per-call allocation was
    /// avoiding a `DateFormatter` hazard that doesn't apply here).
    nonisolated static func displayDate(_ iso: String) -> String {
        guard let date = WorkoutDateFormat.date(iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
