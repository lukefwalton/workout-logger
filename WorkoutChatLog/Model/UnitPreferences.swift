import Foundation

/// The user's preferred weight unit (lb or kg). Shared by `SettingsView`
/// (`@AppStorage`), `TodayModel` (parser default), and the confirm card's unit
/// toggle so a single source of truth controls how an unannotated `100x5` is
/// interpreted. The app never silently converts stored sets — this controls the
/// *default* a new entry is read with, not retroactive history.
///
/// Doctrine: the app stores units verbatim (see `WeightUnit`). If a user logs
/// `100x5` while preferring kg, it is recorded as kg; switching the preference
/// later does not rewrite that row.
enum UnitPreferences {
    /// The user's preferred default unit. `@AppStorage` stores it as a string
    /// (rawValue). Defaults to `.lb` to preserve the historical pre-preference
    /// behavior — existing US users who never opened Settings keep their unit.
    static let defaultUnitKey = "settings.defaultWeightUnit"

    /// Decode a stored rawValue (possibly empty/unset) into a usable unit.
    /// Unrecognized values fall back to `.lb` for the same continuity reason.
    static func resolved(_ stored: String) -> WeightUnit {
        WeightUnit(rawValue: stored) ?? .lb
    }

    /// Read the preference from a `UserDefaults` (default: standard). Used by
    /// non-SwiftUI sites (`TodayModel.init`, tests) that can't use `@AppStorage`.
    static func current(_ defaults: UserDefaults = .standard) -> WeightUnit {
        resolved(defaults.string(forKey: defaultUnitKey) ?? "")
    }
}

/// Body-weight conversions for fields the user enters in their preferred unit
/// while the underlying value stays in kilograms (HealthKit's unit and what
/// `CalorieEstimate` expects). Stored values never silently change — only the
/// edit/display surface converts.
enum BodyweightConversion {
    /// Exact conversion factor: 1 lb = 0.45359237 kg (NIST).
    static let kgPerPound: Double = 0.45359237

    static func kg(fromPounds pounds: Double) -> Double {
        pounds * kgPerPound
    }

    static func pounds(fromKilograms kg: Double) -> Double {
        kg / kgPerPound
    }

    /// Convert a stored kg value into the user's preferred display unit.
    static func display(kg: Double, in unit: WeightUnit) -> Double {
        switch unit {
        case .kg: return kg
        case .lb: return pounds(fromKilograms: kg)
        }
    }

    /// Convert a user-entered value in their preferred unit back to kg for storage.
    static func storedKg(from displayValue: Double, in unit: WeightUnit) -> Double {
        switch unit {
        case .kg: return displayValue
        case .lb: return kg(fromPounds: displayValue)
        }
    }
}
