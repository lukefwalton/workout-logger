import Foundation
@testable import WorkoutChatLog

/// One expected set in a parser fixture (the fields the parser fills; UUID/notes
/// are ignored in comparison).
struct ExpectedSet: Equatable {
    var weight: Double
    var reps: Int
    var unit: WeightUnit = .lb
    var loadKind: WorkoutLoadKind = .external
    var rir: Int? = nil
    var setType: SetType = .working
}

/// A parser fixture: an input line in real shorthand, the expected lowercase
/// exercise span, and the expected sets — or `expected == nil` to assert the
/// deterministic parser *declines* (hands off to Track 2).
///
/// Shared data (not inline in the test) so Track 2 can later run the same set
/// through the LLM and we can compare head-to-head — the experiment the spec
/// cares about.
struct ParserFixture {
    let input: String
    let exercise: String?
    let expected: [ExpectedSet]?
}

private func s(_ weight: Double, _ reps: Int,
               unit: WeightUnit = .lb, loadKind: WorkoutLoadKind? = nil,
               rir: Int? = nil, type: SetType = .working) -> ExpectedSet {
    ExpectedSet(weight: weight,
                reps: reps,
                unit: unit,
                loadKind: loadKind ?? (weight == 0 ? .unspecified : .external),
                rir: rir,
                setType: type)
}

let parserFixtures: [ParserFixture] = [
    // ── weight × reps, single set ──────────────────────────────────────────
    ParserFixture(input: "bench 135x8", exercise: "bench", expected: [s(135, 8)]),
    ParserFixture(input: "Bench Press 225 x 5", exercise: "bench press", expected: [s(225, 5)]),
    ParserFixture(input: "incline db 50x12", exercise: "incline db", expected: [s(50, 12)]),
    ParserFixture(input: "ohp 95x10", exercise: "ohp", expected: [s(95, 10)]),
    ParserFixture(input: "deadlift 405x3", exercise: "deadlift", expected: [s(405, 3)]),
    ParserFixture(input: "curl 30x15", exercise: "curl", expected: [s(30, 15)]),
    ParserFixture(input: "squat 315X5", exercise: "squat", expected: [s(315, 5)]),
    ParserFixture(input: "bench 137.5 x 5", exercise: "bench", expected: [s(137.5, 5)]),
    ParserFixture(input: "ohp 42.5x8", exercise: "ohp", expected: [s(42.5, 8)]),

    // ── weight × reps × sets ───────────────────────────────────────────────
    ParserFixture(input: "incline bench, 135x8x3", exercise: "incline bench", expected: Array(repeating: s(135, 8), count: 3)),
    ParserFixture(input: "bench 225x5x4", exercise: "bench", expected: Array(repeating: s(225, 5), count: 4)),
    ParserFixture(input: "squat 100kgx5x3", exercise: "squat", expected: Array(repeating: s(100, 5, unit: .kg), count: 3)),

    // ── weight × multiple reps (one set per rep) ───────────────────────────
    ParserFixture(input: "bench 135 for 8,8,7", exercise: "bench", expected: [s(135, 8), s(135, 8), s(135, 7)]),
    ParserFixture(input: "squat 225 for 5,5,5,5,5", exercise: "squat", expected: Array(repeating: s(225, 5), count: 5)),
    ParserFixture(input: "row 95x10,9,8", exercise: "row", expected: [s(95, 10), s(95, 9), s(95, 8)]),
    ParserFixture(input: "rdl 185 for 10,10", exercise: "rdl", expected: [s(185, 10), s(185, 10)]),

    // ── sets × reps @ weight ───────────────────────────────────────────────
    ParserFixture(input: "squat 3x10 @ 135", exercise: "squat", expected: Array(repeating: s(135, 10), count: 3)),
    ParserFixture(input: "bench 5x5 @ 185", exercise: "bench", expected: Array(repeating: s(185, 5), count: 5)),
    ParserFixture(input: "leg press 4x12 @ 360", exercise: "leg press", expected: Array(repeating: s(360, 12), count: 4)),
    ParserFixture(input: "hack squat 4x8 @ 270", exercise: "hack squat", expected: Array(repeating: s(270, 8), count: 4)),
    ParserFixture(input: "ohp 8 @ 95", exercise: "ohp", expected: [s(95, 8)]),
    ParserFixture(input: "bench 8 @ 135", exercise: "bench", expected: [s(135, 8)]),
    ParserFixture(input: "deadlift 5 @ 405", exercise: "deadlift", expected: [s(405, 5)]),

    // ── sets × reps, load unspecified until confirmation ───────────────────
    ParserFixture(input: "pushup 3x10", exercise: "pushup", expected: Array(repeating: s(0, 10), count: 3)),
    ParserFixture(input: "pullup 5x5", exercise: "pullup", expected: Array(repeating: s(0, 5), count: 5)),
    ParserFixture(input: "dips 3x12", exercise: "dips", expected: Array(repeating: s(0, 12), count: 3)),
    ParserFixture(input: "10x8", exercise: "", expected: Array(repeating: s(0, 8), count: 10)),
    ParserFixture(input: "11x8", exercise: "", expected: [s(11, 8)]),
    ParserFixture(input: "incline bench 2 sets of 8 reps", exercise: "incline bench", expected: Array(repeating: s(0, 8), count: 2)),
    ParserFixture(input: "row 4 sets 12 reps", exercise: "row", expected: Array(repeating: s(0, 12), count: 4)),
    ParserFixture(input: "incline bench 2 sets of 8", exercise: "incline bench", expected: Array(repeating: s(0, 8), count: 2)),
    ParserFixture(input: "incline bench for 2 sets of 8 reps", exercise: "incline bench", expected: Array(repeating: s(0, 8), count: 2)),

    // ── prose set/reps with load ───────────────────────────────────────────
    ParserFixture(input: "incline bench 2 sets of 8 at 135", exercise: "incline bench", expected: Array(repeating: s(135, 8), count: 2)),
    ParserFixture(input: "bench 2 sets of 8 reps with 135", exercise: "bench", expected: Array(repeating: s(135, 8), count: 2)),
    ParserFixture(input: "bench 8 reps at 60 kg", exercise: "bench", expected: [s(60, 8, unit: .kg)]),
    ParserFixture(input: "curl 12 reps at 30", exercise: "curl", expected: [s(30, 12)]),
    ParserFixture(input: "leg press 10 reps with 360", exercise: "leg press", expected: [s(360, 10)]),

    // ── bodyweight ─────────────────────────────────────────────────────────
    ParserFixture(input: "pullup bw x12", exercise: "pullup", expected: [s(0, 12, loadKind: .bodyweight)]),
    ParserFixture(input: "pushup bw x 20", exercise: "pushup", expected: [s(0, 20, loadKind: .bodyweight)]),
    ParserFixture(input: "dips bodyweight x 8", exercise: "dips", expected: [s(0, 8, loadKind: .bodyweight)]),

    // ── RPE / RIR (rpe → rir = 10 − rpe) ───────────────────────────────────
    ParserFixture(input: "bench 225x5 rpe 8", exercise: "bench", expected: [s(225, 5, rir: 2)]),
    ParserFixture(input: "squat 315x3 rpe 9", exercise: "squat", expected: [s(315, 3, rir: 1)]),
    ParserFixture(input: "ohp 95x8 rir 2", exercise: "ohp", expected: [s(95, 8, rir: 2)]),
    ParserFixture(input: "deadlift 405x2 rpe 10", exercise: "deadlift", expected: [s(405, 2, rir: 0)]),

    // ── units ──────────────────────────────────────────────────────────────
    ParserFixture(input: "bench 60kg x 8", exercise: "bench", expected: [s(60, 8, unit: .kg)]),
    ParserFixture(input: "squat 100 kg x 5", exercise: "squat", expected: [s(100, 5, unit: .kg)]),
    ParserFixture(input: "ohp 135lb x 6", exercise: "ohp", expected: [s(135, 6, unit: .lb)]),
    ParserFixture(input: "row 40 kg for 12,10,8", exercise: "row", expected: [s(40, 12, unit: .kg), s(40, 10, unit: .kg), s(40, 8, unit: .kg)]),
    // Small SEPARATED unit: must be read as weight, not a set count.
    ParserFixture(input: "curl 10 kg x 12", exercise: "curl", expected: [s(10, 12, unit: .kg)]),
    ParserFixture(input: "ohp 5 lb x 15", exercise: "ohp", expected: [s(5, 15, unit: .lb)]),
    ParserFixture(input: "curl 5lbsx8", exercise: "curl", expected: [s(5, 8, unit: .lb)]),
    ParserFixture(input: "row 5kgsx8", exercise: "row", expected: [s(5, 8, unit: .kg)]),

    // ── set-type keywords ──────────────────────────────────────────────────
    ParserFixture(input: "warmup bench 95x10", exercise: "bench", expected: [s(95, 10, type: .warmup)]),
    ParserFixture(input: "bench warmup 135x5", exercise: "bench", expected: [s(135, 5, type: .warmup)]),
    ParserFixture(input: "squat dropset 135x12", exercise: "squat", expected: [s(135, 12, type: .dropset)]),
    ParserFixture(input: "curl 25x15 amrap", exercise: "curl", expected: [s(25, 15, type: .amrap)]),
    ParserFixture(input: "leg curl backoff 90x12", exercise: "leg curl", expected: [s(90, 12, type: .backoff)]),

    // ── combined ───────────────────────────────────────────────────────────
    ParserFixture(input: "incline bench 60kg x 8 rpe 7", exercise: "incline bench", expected: [s(60, 8, unit: .kg, rir: 3)]),
    ParserFixture(input: "bench 185 for 5,5,5 rpe 8", exercise: "bench", expected: Array(repeating: s(185, 5, rir: 2), count: 3)),
    ParserFixture(input: "front squat 3x5 @ 225 rir 1", exercise: "front squat", expected: Array(repeating: s(225, 5, rir: 1), count: 3)),

    // ── multi-word names ───────────────────────────────────────────────────
    ParserFixture(input: "romanian deadlift 225x8", exercise: "romanian deadlift", expected: [s(225, 8)]),
    ParserFixture(input: "close grip bench 155x6", exercise: "close grip bench", expected: [s(155, 6)]),
    ParserFixture(input: "seated cable row 120x12", exercise: "seated cable row", expected: [s(120, 12)]),
    // Numeric-leading name (a real seeded alias) — the spec must be the trailing run.
    ParserFixture(input: "45 degree back extension 100x10", exercise: "45 degree back extension", expected: [s(100, 10)]),

    // ── declined: Track 2's job (multi-exercise, prose, ambiguous, incomplete) ─
    ParserFixture(input: "bench 135x8 squat 225x5", exercise: nil, expected: nil),
    ParserFixture(input: "bench 10 kg x 12 squat 225x5", exercise: nil, expected: nil),
    ParserFixture(input: "135 @ 8", exercise: nil, expected: nil),
    ParserFixture(input: "bench 3x10 kg", exercise: nil, expected: nil),
    ParserFixture(input: "felt strong today, hit a bench PR", exercise: nil, expected: nil),
    ParserFixture(input: "bench press then some squats", exercise: nil, expected: nil),
    ParserFixture(input: "squat 5x5x5", exercise: nil, expected: nil),
    ParserFixture(input: "did 3 sets of bench", exercise: nil, expected: nil),
    ParserFixture(input: "bench 135", exercise: nil, expected: nil),
]
