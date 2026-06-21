import Foundation

/// Layer 3 of the resolution stack (§1.1): on-device semantic embeddings, reached
/// only when fuzzy (Layer 2) is low-confidence. Behind a protocol so **no
/// `NaturalLanguage` symbol leaks into always-compiled code** — the Linux CI and the
/// unit tests build without it. The real implementation
/// (`NLContextualEmbeddingExerciseMatcher`) lives entirely inside
/// `#if canImport(NaturalLanguage)`; tests drive a fake.
///
/// Doctrine (§1.1): like every layer ≥ 2 it **proposes** a candidate the user
/// confirms — it never auto-applies and never merges two distinct canonicals. It is
/// **opportunistic**: any failure (assets not downloaded, simulator, ineligible
/// device) falls through to fuzzy/FM, and it must never block the UI.
protocol ExerciseEmbedding {
    /// Whether embeddings are usable *right now* — the model assets are loaded and a
    /// vector can be produced. False on the simulator, an ineligible device, or
    /// before the system assets finish downloading. Callers check this and fall
    /// through to fuzzy/FM when false.
    var isReady: Bool { get }

    /// A single fixed-length vector for a phrase — the gated implementation embeds
    /// each token and mean-pools them. nil when `isReady` is false or the phrase
    /// can't be embedded. Synchronous and non-blocking: it returns a cached/ready
    /// result or nil, never waits on a download.
    func vector(for text: String) -> [Double]?
}

/// The stand-in used when `NaturalLanguage` isn't compiled in (Linux/CI) or the
/// device can't load embeddings: never ready, so the resolution stack simply stops
/// at fuzzy/FM. This is the shippable bar — embeddings are a bonus rung.
struct NoopEmbedding: ExerciseEmbedding {
    var isReady: Bool { false }
    func vector(for text: String) -> [Double]? { nil }
}

/// Picks the real matcher when the SDK is present and the no-op otherwise. The `#if`
/// is the only place the two worlds meet; callers just get an `ExerciseEmbedding`.
enum ExerciseEmbeddingFactory {
    static func make() -> ExerciseEmbedding {
        #if canImport(NaturalLanguage)
        return NLContextualEmbeddingExerciseMatcher.makeIfAvailable() ?? NoopEmbedding()
        #else
        return NoopEmbedding()
        #endif
    }
}

/// Pure vector math for the semantic layer — cosine similarity and mean-pooling —
/// kept Foundation-only and unit-tested so the ranking logic is verifiable here even
/// though the real embeddings aren't. (The gated matcher may mean-pool via Accelerate
/// `vDSP` for speed; this is the reference, and what the fake uses.)
enum EmbeddingMath {
    /// Cosine similarity of two equal-length vectors, in [-1, 1]. 0 when either is a
    /// zero vector or lengths differ (degenerate → "not similar", never a crash).
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Mean-pool per-token vectors into one. Empty input (or all-empty tokens) → nil.
    /// Ragged token vectors are rejected (nil) rather than silently truncated.
    static func meanPool(_ tokenVectors: [[Double]]) -> [Double]? {
        let vectors = tokenVectors.filter { !$0.isEmpty }
        guard let width = vectors.first?.count, vectors.allSatisfy({ $0.count == width }) else { return nil }
        var sums = [Double](repeating: 0, count: width)
        for vector in vectors {
            for i in 0..<width { sums[i] += vector[i] }
        }
        let count = Double(vectors.count)
        return sums.map { $0 / count }
    }
}
