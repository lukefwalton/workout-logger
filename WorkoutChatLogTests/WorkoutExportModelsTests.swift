import XCTest
@testable import WorkoutChatLog

/// The JSON data-export contract lives in the `Exported*` DTOs
/// (WorkoutExportModels.swift). These tests lock the wire shape directly —
/// encode/decode round-trips and the exact snake_case keys — independent of the
/// database-level import flow already covered by ImportTests.
final class WorkoutExportModelsTests: XCTestCase {

    private func sampleExport() -> WorkoutDataExport {
        let topSet = ExportedSet(
            id: 1, exerciseID: 10, exerciseName: "Bench Press", setIndex: 1, setType: "working",
            load: WorkoutLoad.stored(kind: .external, weight: 135, unit: .lb),
            reps: 8, rir: 2, notes: "top set", sourceText: "bench 135x8 @2", createdAt: "2026-06-01T10:00:00Z")
        let bodyweightSet = ExportedSet(
            id: 2, exerciseID: 11, exerciseName: "Pull-Up", setIndex: 1, setType: "working",
            load: WorkoutLoad.stored(kind: .bodyweight, weight: 0, unit: .lb),
            reps: 10, rir: nil, notes: nil, sourceText: nil, createdAt: "2026-06-01T10:05:00Z")
        let session = ExportedSession(
            id: 100, startedAt: "2026-06-01T10:00:00Z", endedAt: "2026-06-01T10:30:00Z",
            name: "Push", notes: "good", feel: "solid", isDeload: false,
            createdAt: "2026-06-01T10:00:00Z", sets: [topSet, bodyweightSet])
        let exercise = ExportedExercise(
            id: 10, slug: "bench_press", canonicalName: "Bench Press", familyKey: "bench",
            primaryMuscle: "chest", secondaryMuscles: ["triceps", "front delts"],
            isCustom: false, aliases: ["bench", "bp"], createdAt: "2026-01-01T00:00:00Z")
        let fullBout = ExportedCardioEntry(
            id: 1, activity: "Run", durationSeconds: 1800, distance: 5, distanceUnit: .km,
            notes: "easy pace", sourceText: "ran 5k in 30 min", loggedAt: "2026-06-02T07:00:00Z",
            createdAt: "2026-06-02T07:30:00Z")
        let durationOnlyBout = ExportedCardioEntry(
            id: 2, activity: "Cycling", durationSeconds: 2400, distance: nil, distanceUnit: nil,
            notes: nil, sourceText: nil, loggedAt: "2026-06-03T18:00:00Z",
            createdAt: "2026-06-03T18:40:00Z")
        return WorkoutDataExport(
            schemaVersion: 3, exportedAt: "2026-06-21T00:00:00Z", app: "WorkoutChatLog",
            analyticsPolicy: ExportedAnalyticsPolicy(.default),
            exercises: [exercise], sessions: [session],
            cardio: [fullBout, durationOnlyBout])
    }

    func testExportRoundTripsLosslessly() throws {
        let original = sampleExport()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutDataExport.self, from: data)
        XCTAssertEqual(decoded, original, "encode → decode reproduces the export exactly")
    }

    func testExportEmitsSnakeCaseWireKeysAndHidesSwiftNames() throws {
        let json = String(decoding: try JSONEncoder().encode(sampleExport()), as: UTF8.self)
        for key in ["schema_version", "exported_at", "analytics_policy", "canonical_name",
                    "family_key", "primary_muscle", "secondary_muscles", "is_custom",
                    "created_at", "started_at", "ended_at", "is_deload",
                    "exercise_id", "exercise_name", "set_index", "set_type", "source_text",
                    "duration_seconds", "distance_unit", "logged_at"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "export JSON must carry key \"\(key)\"")
        }
        // The camelCase Swift property names must never leak into the persisted format.
        for leaked in ["schemaVersion", "canonicalName", "isCustom", "startedAt", "endedAt",
                       "isDeload", "setIndex", "setType", "sourceText", "exerciseName",
                       "primaryMuscle", "familyKey", "secondaryMuscles", "createdAt",
                       "durationSeconds", "distanceUnit", "loggedAt"] {
            XCTAssertFalse(json.contains("\"\(leaked)\""), "camelCase \"\(leaked)\" must not appear in JSON")
        }
    }

    func testExportTopLevelKeysAreExactlyTheWireContract() throws {
        // A structural check alongside the substring assertions: if a top-level key is
        // renamed or added, this localizes the failure instead of a vague missing substring.
        let data = try JSONEncoder().encode(sampleExport())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(Set((object ?? [:]).keys),
                       ["schema_version", "exported_at", "app", "analytics_policy", "exercises", "sessions", "cardio"],
                       "top-level export keys are frozen")
    }

    func testAnalyticsPolicyExportsSortedRawValuesUnderSnakeCaseKeys() throws {
        let exported = ExportedAnalyticsPolicy(.default)
        XCTAssertEqual(exported.hardSetRIRThreshold, 4)
        XCTAssertTrue(exported.countNullRIRAsHard)
        XCTAssertEqual(exported.workingEquivalentSetTypes, ["amrap", "dropset", "myorep", "working"],
                       "set types map to sorted raw values for a stable export")

        let json = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
        for key in ["hard_set_rir_threshold", "count_null_rir_as_hard", "working_equivalent_set_types"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing key \"\(key)\"")
        }
        XCTAssertEqual(try JSONDecoder().decode(ExportedAnalyticsPolicy.self, from: Data(json.utf8)), exported)
    }

    func testWorkoutLoadRoundTripsPreservingKind() throws {
        // The load is nested Codable inside ExportedSet; a loadless kind must stay
        // loadless (nil amount/unit) rather than resurrecting as "0 lb".
        let loads = [
            WorkoutLoad.stored(kind: .external, weight: 135, unit: .lb),
            WorkoutLoad.stored(kind: .bodyweight, weight: 0, unit: .lb),
            WorkoutLoad.stored(kind: .bodyweightPlus, weight: 25, unit: .lb),
            WorkoutLoad.stored(kind: .assisted, weight: 30, unit: .kg),
            WorkoutLoad.stored(kind: .unspecified, weight: 0, unit: .lb),
        ]
        for load in loads {
            let data = try JSONEncoder().encode(load)
            XCTAssertEqual(try JSONDecoder().decode(WorkoutLoad.self, from: data), load, "round-trip for \(load.kind)")
        }
    }

    func testDecodesWhenCardioKeyAbsent() throws {
        // A v1/v2 file has no top-level "cardio" key; it must decode with an empty
        // cardio array, not throw — backward compat is pinned forever.
        let json = """
        {"schema_version":2,"exported_at":"2026-06-21T00:00:00Z","app":"WorkoutChatLog",
         "analytics_policy":{"hard_set_rir_threshold":4,"count_null_rir_as_hard":true,
                             "working_equivalent_set_types":["working"]},
         "exercises":[],"sessions":[]}
        """
        let export = try JSONDecoder().decode(WorkoutDataExport.self, from: Data(json.utf8))
        XCTAssertEqual(export.schemaVersion, 2)
        XCTAssertTrue(export.cardio.isEmpty, "absent cardio decodes as [], not a throw")
    }

    func testCardioEntryDecodesWithAbsentOptionals() throws {
        // Metric-less bouts ("did some cardio") carry only the required fields.
        let json = #"{"id":7,"activity":"Cardio","logged_at":"2026-06-05T09:00:00Z","created_at":"2026-06-05T09:01:00Z"}"#
        let entry = try JSONDecoder().decode(ExportedCardioEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.id, 7)
        XCTAssertEqual(entry.activity, "Cardio")
        XCTAssertNil(entry.durationSeconds)
        XCTAssertNil(entry.distance)
        XCTAssertNil(entry.distanceUnit)
        XCTAssertNil(entry.notes)
        XCTAssertNil(entry.sourceText)
    }

    func testSessionDecodesWhenOptionalV2FieldsAreAbsent() throws {
        // ended_at and feel are optional on the wire (an open or feelless session);
        // their absence must decode as nil, not throw.
        let json = #"{"id":1,"started_at":"2026-06-01T10:00:00Z","name":null,"notes":null,"is_deload":false,"created_at":"2026-06-01T10:00:00Z","sets":[]}"#
        let session = try JSONDecoder().decode(ExportedSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.id, 1)
        XCTAssertNil(session.endedAt)
        XCTAssertNil(session.feel)
        XCTAssertTrue(session.sets.isEmpty)
    }

    /// The restore-copy contract: preview and completion both compose from
    /// `addedParts`, so an exercise-only restore must surface as an add — the
    /// shipped bug was a completion formatter that skipped `addedExercises`
    /// and finished with "Nothing new to restore" after changing the library.
    func testAddedPartsIncludesExerciseOnlyRestore() {
        var summary = ImportSummary()
        summary.addedExercises = 3
        XCTAssertEqual(summary.addedParts, ["3 new exercises"])

        summary.addedExercises = 1
        XCTAssertEqual(summary.addedParts, ["1 new exercise"])
    }

    func testAddedPartsCoversAllDomainsAndSkippedCountAggregates() {
        var summary = ImportSummary()
        summary.addedSessions = 2
        summary.addedSets = 6
        summary.addedCardio = 1
        summary.addedExercises = 1
        summary.skippedSessions = 3
        summary.skippedCardio = 2
        XCTAssertEqual(summary.addedParts,
                       ["2 workouts and 6 sets", "1 cardio bout", "1 new exercise"])
        XCTAssertEqual(summary.skippedCount, 5)
        XCTAssertTrue(ImportSummary().addedParts.isEmpty,
                      "an all-duplicate restore adds nothing and must read that way")
    }
}
