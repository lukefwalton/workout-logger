import Foundation

/// The Epley estimated-one-rep-max formula in **one** place, so the Progress
/// charts (PR 5) and PR/achievement detection (§4) compute it identically —
/// reuse, not re-derivation. Pure arithmetic; no AI ever touches a number.
enum OneRepMax {
    /// Epley is unreliable past this rep count, so e1RM drops sets above it.
    static let repCap = 12

    /// Epley: `weight × (1 + reps/30)`. The caller decides whether `reps` is in
    /// range (`repCap`); this is just the formula.
    static func epley(weight: Double, reps: Int) -> Double {
        weight * (1 + Double(reps) / 30)
    }
}

/// The kind of personal record detected on save (§4). Three kinds so every lift
/// gets an honest PR moment: loaded lifts via estimated 1RM or weight-at-reps,
/// and bodyweight/calisthenics lifts via max reps.
enum AchievementKind: String, Equatable, Codable {
    case estimatedOneRepMax
    case weightForReps
    case maxReps
}

/// A personal record **computed from logged sets** inside the save transaction —
/// never guessed, never fabricated, and only ever a PR when there is prior
/// history to beat (doctrine: honest data; a PR is a fact, not a guess). It is a
/// transient *notice* surfaced after a save, not a stored analytics fact (§4).
struct Achievement: Equatable, Identifiable {
    let kind: AchievementKind
    let exerciseID: Int64
    let exerciseName: String
    /// The headline number: the e1RM, the weight (`weightForReps`), or the rep
    /// count (`maxReps`, carried as a Double so one field serves every kind).
    let value: Double
    /// The rep count a `weightForReps` PR was set at; nil for the other kinds.
    let reps: Int?
    /// The unit for weight-based PRs (e1RM, `weightForReps`); nil for `maxReps`.
    let unit: WeightUnit?

    /// Stable enough for `ForEach`: one headline PR per exercise per kind.
    var id: String { "\(exerciseID)-\(kind.rawValue)" }

    /// A short, honest, user-facing line. Just the fact — no medical or coaching
    /// claims, and "estimated 1RM" stays labelled as the estimate it is.
    var headline: String {
        switch kind {
        case .estimatedOneRepMax:
            return "New estimated 1RM on \(exerciseName) — \(Self.formatted(value.rounded()))\(unitSuffix)"
        case .weightForReps:
            return "New weight PR on \(exerciseName) — \(Self.formatted(value))\(unitSuffix) × \(reps ?? 0)"
        case .maxReps:
            let r = Int(value.rounded())
            return "New rep PR on \(exerciseName) — \(r) rep\(r == 1 ? "" : "s")"
        }
    }

    private var unitSuffix: String { unit.map { " \($0.rawValue)" } ?? "" }

    /// Integer when whole, else one decimal — matches the app's other number
    /// formatting (e.g. `WorkoutShareSummary`).
    private static func formatted(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded() == rounded ? String(Int(rounded)) : String(rounded)
    }
}

/// Detects the single headline personal record per exercise for a just-saved
/// entry, comparing against that exercise's **own prior history only** — never a
/// family rollup (§1.1 forbids cross-canonical PRs). Pure and unit-tested.
///
/// Honest-or-nothing: the first time a lift is logged is not a PR, ties are not
/// PRs, and unspecified/zero-weight sets never produce a weight PR. Weighted
/// calisthenics (`.bodyweightPlus` and `.assisted`) get their own PR path:
/// added load is compared *within the same load kind* (BW+10×8 vs BW+10×8) —
/// never against a plain external lift — so an assisted set never inflates a
/// loaded PR or vice versa.
enum AchievementDetector {
    /// The minimal facts a PR comparison needs — a projection of a stored set or
    /// a draft set, so the detector stays free of DB and draft concerns.
    struct SetFact: Equatable {
        let exerciseID: Int64
        let loadKind: WorkoutLoadKind
        let weight: Double?
        let unit: WeightUnit?
        let reps: Int
    }

    /// Float-comparison guard so e1RM/weight ties never read as a PR.
    private static let epsilon = 1e-9

    /// One headline achievement per exercise present in `saved`, or none.
    /// `priorByExercise[id]` is that exercise's sets logged *before* this entry;
    /// `nameByExercise[id]` supplies the display name for the notice. Results are
    /// ordered by exercise id so the surfaced notices are deterministic.
    static func achievements(saved: [SetFact],
                             priorByExercise: [Int64: [SetFact]],
                             nameByExercise: [Int64: String]) -> [Achievement] {
        Dictionary(grouping: saved, by: \.exerciseID).keys.sorted().compactMap { id in
            achievement(exerciseID: id,
                        saved: saved.filter { $0.exerciseID == id },
                        prior: priorByExercise[id] ?? [],
                        name: nameByExercise[id] ?? "")
        }
    }

    /// Priority per exercise: estimated 1RM, then heaviest-weight-at-a-rep-count
    /// (both loaded), else max reps (bodyweight). At most one, to keep the notice
    /// tasteful.
    ///
    /// The "any external set ⇒ loaded path" routing assumes one load style per
    /// exercise per saved entry. That holds on the only path that calls this — the
    /// parser emits a single load for an entry and `TodayModel.setWeight` forces a
    /// uniform `loadKind` across its sets — so a single save never mixes external
    /// and bodyweight work for the same lift. If a future writer breaks that, the
    /// worst case is a loaded PR shown instead of a rep PR, never a fabricated one.
    private static func achievement(exerciseID: Int64, saved: [SetFact],
                                    prior: [SetFact], name: String) -> Achievement? {
        let savedExternal = saved.filter { $0.loadKind == .external && ($0.weight ?? 0) > 0 }
        if !savedExternal.isEmpty {
            let priorExternal = prior.filter { $0.loadKind == .external && ($0.weight ?? 0) > 0 }
            if let pr = estimatedOneRepMaxPR(exerciseID: exerciseID, name: name,
                                             saved: savedExternal, prior: priorExternal) {
                return pr
            }
            return weightForRepsPR(exerciseID: exerciseID, name: name,
                                   saved: savedExternal, prior: priorExternal)
        }

        // Weighted calisthenics: dip/pull-up with a belt, assisted machines, …
        // Compared *only* within the same load kind so an assisted PR never
        // displaces a bodyweight one. Direction matters: more added load is a
        // PR for `.bodyweightPlus`; *less* assistance is a PR for `.assisted`.
        let savedPlus = saved.filter { $0.loadKind == .bodyweightPlus && ($0.weight ?? 0) > 0 }
        if !savedPlus.isEmpty {
            let priorPlus = prior.filter { $0.loadKind == .bodyweightPlus && ($0.weight ?? 0) > 0 }
            if let pr = addedLoadPR(exerciseID: exerciseID, name: name,
                                    saved: savedPlus, prior: priorPlus,
                                    moreIsBetter: true) {
                return pr
            }
        }
        let savedAssisted = saved.filter { $0.loadKind == .assisted && ($0.weight ?? 0) > 0 }
        if !savedAssisted.isEmpty {
            let priorAssisted = prior.filter { $0.loadKind == .assisted && ($0.weight ?? 0) > 0 }
            if let pr = addedLoadPR(exerciseID: exerciseID, name: name,
                                    saved: savedAssisted, prior: priorAssisted,
                                    moreIsBetter: false) {
                return pr
            }
        }

        return maxRepsPR(exerciseID: exerciseID, name: name, saved: saved, prior: prior)
    }

    private static func estimatedOneRepMaxPR(exerciseID: Int64, name: String,
                                             saved: [SetFact], prior: [SetFact]) -> Achievement? {
        func e1RM(_ s: SetFact) -> Double { OneRepMax.epley(weight: s.weight ?? 0, reps: s.reps) }
        // Compare only against prior history in the *same unit*: the app never silently
        // converts lb↔kg (see `WeightUnit`), so a cross-unit "PR" would be a fabricated
        // number. Epley applies only within its rep cap, on both sides.
        let candidates = saved.filter { $0.reps <= OneRepMax.repCap }.filter { set in
            guard let priorBest = prior.filter({ $0.unit == set.unit && $0.reps <= OneRepMax.repCap })
                .map(e1RM).max() else { return false }   // no same-unit history to beat
            return e1RM(set) > priorBest + epsilon
        }
        guard let best = candidates.max(by: { e1RM($0) < e1RM($1) }) else { return nil }
        return Achievement(kind: .estimatedOneRepMax, exerciseID: exerciseID, exerciseName: name,
                           value: e1RM(best), reps: nil, unit: best.unit)
    }

    private static func weightForRepsPR(exerciseID: Int64, name: String,
                                        saved: [SetFact], prior: [SetFact]) -> Achievement? {
        // Heaviest prior weight at each (unit, rep count) the lift has actually done —
        // keyed by unit because lb and kg weights are never directly comparable (the app
        // doesn't silently convert).
        struct UnitReps: Hashable { let unit: WeightUnit?; let reps: Int }
        var priorMax: [UnitReps: Double] = [:]
        for s in prior {
            let key = UnitReps(unit: s.unit, reps: s.reps)
            priorMax[key] = max(priorMax[key] ?? 0, s.weight ?? 0)
        }
        // Qualifying saved sets: those that beat the lift's own prior best at the same
        // (unit, rep count). Each carries how much it beat *its own unit's* history by.
        let beaters = saved.compactMap { s -> (set: SetFact, improvement: Double)? in
            guard let priorWeight = priorMax[UnitReps(unit: s.unit, reps: s.reps)],
                  let weight = s.weight, weight > priorWeight + epsilon else { return nil }
            return (s, weight - priorWeight)
        }
        // Pick the headline by *improvement over own-unit history*, never by comparing raw
        // weights across units (which aren't comparable). Ties resolve deterministically by
        // reps, then weight, then unit — so a mixed-unit entry still yields a stable result.
        guard let best = beaters.max(by: { lhs, rhs in
            if lhs.improvement != rhs.improvement { return lhs.improvement < rhs.improvement }
            if lhs.set.reps != rhs.set.reps { return lhs.set.reps < rhs.set.reps }
            if (lhs.set.weight ?? 0) != (rhs.set.weight ?? 0) { return (lhs.set.weight ?? 0) < (rhs.set.weight ?? 0) }
            return (lhs.set.unit?.rawValue ?? "") < (rhs.set.unit?.rawValue ?? "")
        })?.set, let weight = best.weight else { return nil }
        return Achievement(kind: .weightForReps, exerciseID: exerciseID, exerciseName: name,
                           value: weight, reps: best.reps, unit: best.unit)
    }

    /// Weighted calisthenics PR: `bodyweightPlus` (added belt weight) or
    /// `assisted` (machine assistance). Compared *within the same load kind* and
    /// at the same `(unit, reps)` so a 10 lb belt PR doesn't pretend to beat a
    /// 5 kg one. Direction is set by `moreIsBetter` — added load wants *more*,
    /// assistance wants *less*. Returns at most one PR.
    private static func addedLoadPR(exerciseID: Int64, name: String,
                                    saved: [SetFact], prior: [SetFact],
                                    moreIsBetter: Bool) -> Achievement? {
        struct UnitReps: Hashable { let unit: WeightUnit?; let reps: Int }
        // The "best" prior at each (unit, reps) — max for plus, min for assisted.
        var priorBest: [UnitReps: Double] = [:]
        for s in prior {
            guard let weight = s.weight else { continue }
            let key = UnitReps(unit: s.unit, reps: s.reps)
            if let current = priorBest[key] {
                priorBest[key] = moreIsBetter ? max(current, weight) : min(current, weight)
            } else {
                priorBest[key] = weight
            }
        }
        let beaters = saved.compactMap { s -> (set: SetFact, improvement: Double)? in
            guard let weight = s.weight,
                  let priorWeight = priorBest[UnitReps(unit: s.unit, reps: s.reps)] else { return nil }
            let improvement = moreIsBetter ? weight - priorWeight : priorWeight - weight
            guard improvement > epsilon else { return nil }
            return (s, improvement)
        }
        guard let best = beaters.max(by: { lhs, rhs in
            if lhs.improvement != rhs.improvement { return lhs.improvement < rhs.improvement }
            if lhs.set.reps != rhs.set.reps { return lhs.set.reps < rhs.set.reps }
            return (lhs.set.weight ?? 0) < (rhs.set.weight ?? 0)
        })?.set, let weight = best.weight else { return nil }
        return Achievement(kind: .weightForReps, exerciseID: exerciseID, exerciseName: name,
                           value: weight, reps: best.reps, unit: best.unit)
    }

    private static func maxRepsPR(exerciseID: Int64, name: String,
                                  saved: [SetFact], prior: [SetFact]) -> Achievement? {
        // **Genuine bodyweight only.** `.unspecified` means the load is unknown/
        // unconfirmed, not a real calisthenics set — counting its reps would invent a
        // PR from data the user never actually committed to (honest-or-nothing, §4).
        // So a rep PR fires only for `.bodyweight` work, on both sides.
        func bodyweight(_ s: SetFact) -> Bool { s.loadKind == .bodyweight }
        guard let savedMax = saved.filter(bodyweight).map(\.reps).max(),
              let priorMax = prior.filter(bodyweight).map(\.reps).max(),   // prior must exist to beat
              savedMax > priorMax else { return nil }
        return Achievement(kind: .maxReps, exerciseID: exerciseID, exerciseName: name,
                           value: Double(savedMax), reps: nil, unit: nil)
    }
}
