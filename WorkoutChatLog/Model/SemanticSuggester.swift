import Foundation

/// Layer 3's ranking (§1.1, "PR 7"): given an `ExerciseEmbedding` and the canonical
/// registry, propose the semantically nearest existing canonicals for an
/// unrecognized query. Pure and unit-tested (with a fake embedding); it **proposes**
/// `ExerciseSuggestion`s with `via: .semantic`, surfaced through the same
/// "Did you mean…?" confirm path as fuzzy — the user still confirms, and two
/// distinct canonicals are never merged.
///
/// Opportunistic by construction: when the embedding isn't ready, or the query/
/// canonicals can't be embedded, it returns `[]` and the caller keeps whatever
/// fuzzy/FM produced. It never throws and never blocks.
struct SemanticSuggester {
    /// One canonical to rank against, with its name embedded once and cached by the
    /// caller (embedding the whole registry on every keystroke would be wasteful).
    struct Candidate: Equatable {
        let exerciseID: Int64
        let canonicalName: String
        let familyKey: String?
        let vector: [Double]
    }

    let embedding: ExerciseEmbedding
    /// Keep candidates at/above this cosine score (spec's ~0.80 floor). Confirm
    /// against the real metric on device — this is the reference threshold.
    var threshold: Double = 0.80

    /// Ranked semantic candidates for `query`, best first, capped at `limit`. Empty
    /// when embeddings aren't ready or nothing clears the threshold.
    func suggestions(for query: String, among candidates: [Candidate], limit: Int = 3) -> [ExerciseSuggestion] {
        guard embedding.isReady, let queryVector = embedding.vector(for: query) else { return [] }
        return candidates.compactMap { candidate -> ExerciseSuggestion? in
            let score = EmbeddingMath.cosineSimilarity(queryVector, candidate.vector)
            guard score >= threshold else { return nil }
            return ExerciseSuggestion(exerciseID: candidate.exerciseID,
                                      canonicalName: candidate.canonicalName,
                                      familyKey: candidate.familyKey,
                                      score: score, via: .semantic)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.canonicalName < $1.canonicalName   // deterministic tie-break
        }
        .prefix(limit)
        .map { $0 }
    }
}
