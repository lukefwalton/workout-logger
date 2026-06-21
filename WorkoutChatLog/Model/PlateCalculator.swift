import Foundation

/// A barbell loadout: which plates go on **each side**, what total that actually
/// achieves, and how far it is from the requested target. Honest by construction
/// (§4) — when a target can't be made exactly from the available plates, the
/// result says so and reports the nearest-achievable load plus the leftover,
/// rather than silently rounding to a wrong number.
struct PlateLoadout: Equatable {
    /// Plates for one side, largest first (mirror them on the other side).
    let perSide: [Double]
    /// The weight `bar + 2 × Σ perSide` this loadout actually puts on the bar.
    let achieved: Double
    /// `target − achieved`. `0` when exact; positive when the bar is under the
    /// target (couldn't reach it), negative when the target is below the bar.
    let remainder: Double
    let unit: WeightUnit

    /// True only when the available plates hit the target exactly.
    var isExact: Bool { abs(remainder) < PlateCalculator.epsilon }
}

/// Pure barbell-plate math (spec §4): `(target, bar, availablePlates, unit) →
/// plates per side`, or an honest nearest-achievable result. No store, no UI, no
/// AI — just arithmetic, fully unit-tested. Plates load symmetrically, so the
/// math works on per-side weight `(target − bar) / 2` and reports one side.
enum PlateCalculator {
    static let epsilon = 1e-6

    /// Common plate inventories, largest first. A sensible default the picker can
    /// start from; the function itself takes whatever set the caller supplies.
    static let defaultPlatesLb: [Double] = [45, 35, 25, 10, 5, 2.5]
    static let defaultPlatesKg: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]

    /// Common bar weights per unit, descending — the picker's "what bar?" options. `0`
    /// is the "no bar" sentinel for accessories. Centralized here so `TodayView`'s plate
    /// picker reads from the same source as `defaultPlates(for:)`.
    static let defaultBarsLb: [Double] = [45, 35, 15, 0]
    static let defaultBarsKg: [Double] = [20, 15, 10, 7.5, 0]

    static func defaultPlates(for unit: WeightUnit) -> [Double] {
        unit == .kg ? defaultPlatesKg : defaultPlatesLb
    }

    static func defaultBars(for unit: WeightUnit) -> [Double] {
        unit == .kg ? defaultBarsKg : defaultBarsLb
    }

    /// The loadout for `target`, greedily loading the largest plate that still
    /// fits per side. Returns nil only for a nonsensical bar (non-finite or
    /// negative); an unreachable target is **not** nil — it comes back as a
    /// non-exact loadout with the nearest-achievable `achieved` and the
    /// `remainder`, so the UI can be honest about it.
    ///
    /// - A target below the bar yields an empty loadout (just the bar) with a
    ///   negative remainder — you can't load less than the bar.
    /// - Plates are assumed available in pairs; denominations ≤ 0 are ignored.
    static func loadout(target: Double,
                        bar: Double,
                        plates: [Double],
                        unit: WeightUnit) -> PlateLoadout? {
        guard bar.isFinite, bar >= 0, target.isFinite else { return nil }

        // Below (or at) the bar: nothing to load. Exact only when target == bar.
        guard target > bar + epsilon else {
            return PlateLoadout(perSide: [], achieved: bar, remainder: target - bar, unit: unit)
        }

        let perSideTarget = (target - bar) / 2
        let denominations = plates.filter { $0 > 0 }.sorted(by: >)
        var chosen: [Double] = []
        var remaining = perSideTarget
        for plate in denominations {
            while remaining + epsilon >= plate {
                chosen.append(plate)
                remaining -= plate
            }
        }
        let achieved = bar + 2 * chosen.reduce(0, +)
        return PlateLoadout(perSide: chosen, achieved: achieved, remainder: target - achieved, unit: unit)
    }

    /// "45 + 25 + 2.5" — the per-side plates as a readable string, or "just the
    /// bar" when nothing loads.
    static func perSideText(_ loadout: PlateLoadout) -> String {
        guard !loadout.perSide.isEmpty else { return "just the bar" }
        return loadout.perSide.map(format).joined(separator: " + ")
    }

    /// Integer when whole, else up to **two** decimals with trailing zeros trimmed
    /// (45 → "45", 2.5 → "2.5", 1.25 → "1.25"). Two decimals matters: the default kg
    /// inventory includes a 1.25 kg plate, and one-decimal rounding would render it
    /// as a non-existent "1.3" denomination.
    static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded.rounded() == rounded { return String(Int(rounded)) }
        // "%.2f" then trim trailing zeros: 1.25 → "1.25", 2.50 → "2.5".
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
