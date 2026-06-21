import Foundation

/// State + logic behind the Today tab's supplement check-off, backed by the SQLite
/// store (the single source of truth — same DB as workouts), so intake history can
/// trend over time in Progress. It's recall plus history, not workout analytics, so
/// it lives in its own tables and never touches the set/session write path.
///
/// The **taken** state is per local calendar day; reloading on a new day (or on
/// `refreshForToday()`) shows an empty day. The configured **list** persists.
///
/// `@MainActor` because it owns published UI state and calls the main-actor mutating
/// store APIs; the store's reads stay non-isolated.
@MainActor
final class SupplementModel: ObservableObject {
    @Published private(set) var supplements: [Supplement] = []
    /// supplement id → today's intake (presence = taken; grams optional).
    @Published private(set) var intakeToday: [Int64: SupplementIntake] = [:]
    /// Set after a rejected add (blank/duplicate) so the UI can explain itself.
    @Published var addError: String?
    /// Set when a store read/write fails, so the card shows a real failure state
    /// instead of looking empty or like a dead tap — important now that startup runs
    /// the first schema migration and a failure would otherwise be invisible.
    @Published private(set) var storeError: String?

    private let store: WorkoutStore
    private let calendar: Calendar
    private let now: () -> Date

    /// The day the published `intakeToday` snapshot represents — re-read when it goes
    /// stale (a new day) so checks clear at midnight.
    private(set) var loadedDay: String = ""

    init(store: WorkoutStore, calendar: Calendar = .current, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.calendar = calendar
        self.now = now
        load()
    }

    var todayKey: String { SupplementDay.key(for: now(), calendar: calendar) }

    func isTaken(_ id: Int64) -> Bool { intakeToday[id] != nil }

    func grams(_ id: Int64) -> Double? { intakeToday[id]?.grams }

    /// Toggle a supplement's taken state for today. Preserves any grams already set
    /// when re-checking is not involved (a fresh check starts with no grams).
    func toggle(_ id: Int64) {
        storeError = nil
        let nowTaken = !isTaken(id)
        do {
            try store.setSupplementIntake(supplementID: id, day: todayKey, taken: nowTaken,
                                          grams: nowTaken ? grams(id) : nil)
            reloadToday()
        } catch {
            fail("Couldn't update that supplement.", error)
        }
    }

    /// Set protein-style grams for today (implies taken). A nil/zero clears grams but
    /// keeps it taken.
    func setGrams(_ id: Int64, grams rawGrams: Double?) {
        storeError = nil
        let grams = rawGrams.map { max(0, $0) }
        do {
            try store.setSupplementIntake(supplementID: id, day: todayKey, taken: true, grams: grams)
            reloadToday()
        } catch {
            fail("Couldn't update that supplement.", error)
        }
    }

    @discardableResult
    func addSupplement(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            addError = "Enter a name first."
            return false
        }
        do {
            guard try store.addSupplement(named: name) != nil else {
                addError = "\"\(name)\" is already in your list."
                return false
            }
            addError = nil
            storeError = nil
            reloadList()
            return true
        } catch {
            addError = "Couldn't add that. Try again."
            #if DEBUG
            print("[SupplementModel] addSupplement failed: \(error)")
            #endif
            return false
        }
    }

    func removeSupplement(_ id: Int64) {
        storeError = nil
        do {
            try store.removeSupplement(id)
            reloadList()
            reloadToday()
        } catch {
            fail("Couldn't remove that supplement.", error)
        }
    }

    /// Re-evaluate the day boundary (call on appear / app foreground) so checks clear
    /// at midnight even if the view stayed on-screen.
    func refreshForToday() {
        guard loadedDay != todayKey else { return }
        storeError = nil
        reloadToday()
    }

    // MARK: - Loading

    // `storeError` is cleared once at the *start* of an operation; the individual
    // reads below only ever *set* it on failure. That way a second successful read
    // can't wipe a failure the first read just recorded.

    private func load() {
        storeError = nil
        reloadList()
        reloadToday()
    }

    private func reloadList() {
        do {
            supplements = try store.supplements()
        } catch {
            // Preserve whatever we last showed rather than blanking the list.
            fail("Couldn't load your supplements.", error)
        }
    }

    private func reloadToday() {
        let day = todayKey
        do {
            intakeToday = try store.supplementIntake(onDay: day)
            loadedDay = day
        } catch {
            fail("Couldn't load today's supplements.", error)
        }
    }

    private func fail(_ message: String, _ error: Error) {
        storeError = message
        #if DEBUG
        print("[SupplementModel] \(message): \(error)")
        #endif
    }
}
