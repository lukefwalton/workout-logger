import Foundation

/// The unit a set's weight is recorded in. Stored verbatim — the app never
/// silently converts, so an exported row reads back exactly as it was logged.
enum WeightUnit: String, Codable, CaseIterable {
    case lb, kg
}

/// What kind of set this is. Drives analytics policy (which set types count as
/// working-equivalent and toward "hard sets") rather than being interpreted ad
/// hoc in queries — see `AnalyticsPolicy`.
enum SetType: String, Codable, CaseIterable {
    case working, warmup, dropset, myorep, amrap, backoff
}

/// Why a set's load has the numeric shape it has. A zero weight can be a real
/// bodyweight set or an unknown load waiting for confirmation; keep that intent
/// explicit instead of reverse-engineering it from text later.
enum WorkoutLoadKind: String, Codable, CaseIterable {
    case external
    case bodyweight
    case unspecified
    case bodyweightPlus
    case assisted
}

/// How a finished session felt overall. Set at finish (PR 3), honest and
/// optional — an off day shouldn't read as a regression, so analytics can
/// exclude it (PR 5). Rendered with SF Symbols, never emoji.
enum SessionFeel: String, Codable, CaseIterable {
    case solid, neutral, off
    var label: String {
        switch self {
        case .solid: "Solid"
        case .neutral: "OK"
        case .off: "Off day"
        }
    }
    var symbol: String {
        switch self {
        case .solid: "arrow.up.circle.fill"
        case .neutral: "equal.circle.fill"
        case .off: "arrow.down.circle.fill"
        }
    }
}

/// One proposed set, before it is written. Whether it came from typed chat, a
/// quick-log tap, or a correction, it lands here first. `rir` stays nil unless
/// the user stated it — never guessed — because a fabricated RIR quietly
/// poisons hard-set analytics.
struct SetDraft: Identifiable, Equatable {
    let id = UUID()
    var exerciseName: String          // raw or canonical; resolved at save
    var weight: Double
    var unit: WeightUnit
    var loadKind: WorkoutLoadKind = .external
    var reps: Int
    var rir: Int?                      // null unless stated — never guessed
    var setType: SetType = .working
    var notes: String?
    var sourceText: String?           // provenance: "quick_log" or the raw chat text
}

/// A whole proposed workout. The keystone contract of the app: every input path
/// produces one of these, and every draft flows through the same
/// validate -> transaction -> write path (`WorkoutStore.save`). The DB layer
/// does not care where a draft came from.
struct WorkoutDraft: Identifiable {
    let id = UUID()
    var startedAt: Date
    var name: String?
    var notes: String?
    var sets: [SetDraft]
    // Session-level annotations, set at finish (PR 3). Defaults keep every
    // existing call site — which constructs a draft without them — compiling.
    var feel: SessionFeel? = nil
    var isDeload: Bool = false
}

/// The immutable identity of a canonical exercise (spec §1.1). `id` is the
/// rowid that `sets.exercise_id` references — it never changes when a display
/// name changes. `slug` is the stable seed/import key. Aliases live in their own
/// table (owned 1:1), so they are not a field here. `familyKey` is for browsing
/// only and never collapses progression or PRs.
struct Exercise: Equatable {
    let id: Int64
    let slug: String
    var canonicalName: String
    var familyKey: String?
    var primaryMuscle: String?
    var secondaryMuscles: [String]
}

/// Read snapshot of the one open (in-progress) session — the row with
/// `ended_at IS NULL`. The DB row is the source of truth; this is a cheap
/// value copy for the UI and the widget (PR 12). `lastSetAt` is nil only
/// transiently, because sessions open lazily on the first saved set.
struct OpenSession: Equatable {
    let id: Int64
    let startedAt: Date
    let lastSetAt: Date?
    let name: String?
    let setCount: Int
}
