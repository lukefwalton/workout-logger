import XCTest
@testable import WorkoutChatLog

/// Bodyweight is stored in kg (HealthKit + CalorieEstimate expect kg) but the
/// Settings field shows + accepts the user's preferred unit. The conversion is
/// the surface that prevents a 2.2× off-by-unit error in the calorie estimate.
final class BodyweightConversionTests: XCTestCase {

    /// 1 lb = 0.45359237 kg exactly (NIST).
    func testPoundsToKilogramsExactConstant() {
        XCTAssertEqual(BodyweightConversion.kg(fromPounds: 1.0), 0.45359237, accuracy: 1e-9)
    }

    func testKilogramsToPoundsRoundTrip() {
        let original = 80.0
        let pounds = BodyweightConversion.pounds(fromKilograms: original)
        let kg = BodyweightConversion.kg(fromPounds: pounds)
        XCTAssertEqual(kg, original, accuracy: 1e-9)
    }

    /// A US user typing 180 in the (lb) field stores ~81.6 kg, not 180 kg.
    func testTypicalUSBodyweightStoredAsKilograms() {
        let stored = BodyweightConversion.storedKg(from: 180, in: .lb)
        XCTAssertEqual(stored, 81.646626, accuracy: 1e-5)
    }

    /// A kg-preferring user typing 80 stores 80 (no conversion).
    func testKilogramUserStoresExactly() {
        XCTAssertEqual(BodyweightConversion.storedKg(from: 80, in: .kg), 80)
    }

    /// The display side is the inverse: storage 80 kg shows 80 in the kg field,
    /// ~176 in the lb field.
    func testDisplayInPreferredUnit() {
        XCTAssertEqual(BodyweightConversion.display(kg: 80, in: .kg), 80)
        XCTAssertEqual(BodyweightConversion.display(kg: 80, in: .lb), 176.369809, accuracy: 1e-5)
    }

    /// Zero round-trips to zero in either unit so an unset field stays "—".
    func testZeroRoundTripsInBothUnits() {
        XCTAssertEqual(BodyweightConversion.storedKg(from: 0, in: .lb), 0)
        XCTAssertEqual(BodyweightConversion.storedKg(from: 0, in: .kg), 0)
        XCTAssertEqual(BodyweightConversion.display(kg: 0, in: .lb), 0)
        XCTAssertEqual(BodyweightConversion.display(kg: 0, in: .kg), 0)
    }

    /// Toggling units must not mutate storage. The Settings field's
    /// `bodyweightDisplay` binding computes display from `manualBodyweightKg`
    /// purely on read, so a unit flip is a display-only event: the stored
    /// kg value must come through both lenses unchanged.
    func testUnitTogglePreservesStoredKilograms() {
        let storedKg = 81.646626   // ~180 lb user
        // Display under each unit is just a different view of the same value.
        let asLb = BodyweightConversion.display(kg: storedKg, in: .lb)
        let asKg = BodyweightConversion.display(kg: storedKg, in: .kg)
        // Storing the displayed value back under the same unit must return kg.
        XCTAssertEqual(BodyweightConversion.storedKg(from: asLb, in: .lb), storedKg, accuracy: 1e-9)
        XCTAssertEqual(BodyweightConversion.storedKg(from: asKg, in: .kg), storedKg, accuracy: 1e-9)
    }

    /// A round-trip through both units is the load-bearing invariant of the
    /// Settings binding: edit in lb (stored as kg), toggle to kg (show kg),
    /// toggle back to lb — the displayed value must be the original entry.
    func testLbToKgToLbRoundTripStableThroughTheBinding() {
        let userEnteredLb = 185.5
        let storedKg = BodyweightConversion.storedKg(from: userEnteredLb, in: .lb)
        // ...user toggles to kg, sees the kg value, doesn't edit, toggles back.
        let backToLb = BodyweightConversion.display(kg: storedKg, in: .lb)
        XCTAssertEqual(backToLb, userEnteredLb, accuracy: 1e-9)
    }
}
