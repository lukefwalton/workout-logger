import Foundation

/// One row of the seeded canonical exercise library, decoded from
/// `seed_exercises.json`. Muscle names use the public-domain free-exercise-db
/// vocabulary (17 groups; see NOTICE.md). `aliases` are lowercase shorthand a
/// user might type ("ohp", "rdl", "db row").
///
/// `slug` is the stable seed/import key (e.g. `"close_grip_push_up"`): it never
/// changes, is what reseeding upserts on, and is what import (PR 13) matches by —
/// so a seed entry can be re-described without losing the user's history.
/// `familyKey` groups related canonicals for browsing only (never analytics);
/// nil means a singleton.
struct SeedExercise: Codable, Equatable {
    var slug: String
    var canonicalName: String
    var familyKey: String?
    var primaryMuscle: String?
    var secondaryMuscles: [String]
    var aliases: [String]

    enum CodingKeys: String, CodingKey {
        case slug
        case canonicalName = "canonical_name"
        case familyKey = "family_key"
        case primaryMuscle = "primary_muscle"
        case secondaryMuscles = "secondary_muscles"
        case aliases
    }
}

enum ExerciseSeed {
    enum SeedError: Error { case missingResource }

    /// Loads the bundled seed library. Defaults to the main app bundle; tests
    /// pass their own bundle so they can seed without hosting into the app.
    static func load(from bundle: Bundle = .main) throws -> [SeedExercise] {
        guard let url = bundle.url(forResource: "seed_exercises", withExtension: "json") else {
            throw SeedError.missingResource
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([SeedExercise].self, from: data)
    }
}
