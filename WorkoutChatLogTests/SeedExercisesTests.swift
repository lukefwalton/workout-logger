import XCTest
@testable import WorkoutChatLog

final class SeedExercisesTests: XCTestCase {

    // The free-exercise-db muscle vocabulary (public domain). The seed's muscle
    // map is the one non-negotiable correctness surface — a tag outside this set
    // would silently rot per-muscle analytics.
    private let vocabulary: Set<String> = [
        "abdominals", "abductors", "adductors", "biceps", "calves", "chest",
        "forearms", "glutes", "hamstrings", "lats", "lower back", "middle back",
        "neck", "quadriceps", "shoulders", "traps", "triceps"
    ]

    private func loadSeeds() throws -> [SeedExercise] {
        try ExerciseSeed.load(from: Bundle(for: Self.self))
    }

    func testSeedLoadsEightyNineLifts() throws {
        XCTAssertEqual(try loadSeeds().count, 89)
    }

    func testCanonicalNamesAreUnique() throws {
        let names = try loadSeeds().map { $0.canonicalName.lowercased() }
        XCTAssertEqual(Set(names).count, names.count, "canonical names must be unique")
    }

    func testEverySeedHasASlug() throws {
        for seed in try loadSeeds() {
            XCTAssertFalse(seed.slug.isEmpty, "\(seed.canonicalName) is missing a slug")
        }
    }

    func testSlugsAreUnique() throws {
        let slugs = try loadSeeds().map { $0.slug }
        XCTAssertEqual(Set(slugs).count, slugs.count, "slugs must be unique — they are the import key")
    }

    func testAliasesAreGloballyUnique() throws {
        let aliases = try loadSeeds().flatMap { $0.aliases.map { $0.lowercased() } }
        XCTAssertEqual(Set(aliases).count, aliases.count, "an alias must map to exactly one lift")
    }

    func testAliasesStayUniqueUnderRuntimeNormalization() throws {
        // The store keys exercise_aliases on WorkoutStore.normalizeAlias and inserts
        // with OR IGNORE, so two seed aliases differing only by case or whitespace
        // would silently collide at seed time (one quietly dropped). Check with the
        // exact runtime normalization, not a looser lowercased() compare.
        let normalized = try loadSeeds().flatMap { $0.aliases.map(WorkoutStore.normalizeAlias) }
        XCTAssertEqual(Set(normalized).count, normalized.count,
                       "aliases must stay unique under WorkoutStore.normalizeAlias, or one is lost at seed time")
    }

    func testNoAliasCollidesWithAnotherCanonicalName() throws {
        // Resolution is exact-canonical → alias, so an alias equal to a *different*
        // lift's canonical name would be shadowed by the exact match and silently
        // resolve to the wrong exercise.
        let seeds = try loadSeeds()
        let canonicals = Set(seeds.map { $0.canonicalName.lowercased() })
        for seed in seeds {
            for alias in seed.aliases where alias.lowercased() != seed.canonicalName.lowercased() {
                XCTAssertFalse(canonicals.contains(alias.lowercased()),
                               "alias \"\(alias)\" on \(seed.canonicalName) collides with another exercise's canonical name")
            }
        }
    }

    func testEveryMuscleIsInVocabulary() throws {
        for seed in try loadSeeds() {
            if let primary = seed.primaryMuscle {
                XCTAssertTrue(vocabulary.contains(primary), "unknown primary muscle: \(primary)")
            }
            for secondary in seed.secondaryMuscles {
                XCTAssertTrue(vocabulary.contains(secondary), "unknown secondary muscle: \(secondary)")
            }
        }
    }

    func testPrimaryMuscleIsNotAlsoSecondary() throws {
        for seed in try loadSeeds() {
            if let primary = seed.primaryMuscle {
                XCTAssertFalse(seed.secondaryMuscles.contains(primary),
                               "\(seed.canonicalName) lists its primary muscle as secondary")
            }
        }
    }

    func testEverySeedHasAPrimaryMuscle() throws {
        for seed in try loadSeeds() {
            XCTAssertNotNil(seed.primaryMuscle, "\(seed.canonicalName) is missing a primary muscle")
        }
    }
}
