import XCTest
@testable import WorkoutChatLog

/// A scripted `ExerciseEmbedding` for the Layer-3 tests — never imports
/// `NaturalLanguage`. Returns fixed fixture vectors by phrase, so cosine ranking is
/// exercised deterministically without the real model.
final class FakeEmbedding: ExerciseEmbedding {
    var ready: Bool
    var vectors: [String: [Double]]

    init(ready: Bool = true, vectors: [String: [Double]] = [:]) {
        self.ready = ready
        self.vectors = vectors
    }

    var isReady: Bool { ready }
    func vector(for text: String) -> [Double]? { vectors[text] }
}

/// Layer 3 (semantic) ranking (§1.1, "PR 7"): cosine math, mean-pooling, and the
/// suggester's propose-and-confirm behavior — all with a fake embedding, no
/// `NaturalLanguage` import. The real `NLContextualEmbedding` behavior is a
/// human-on-device acceptance step.
final class SemanticSuggesterTests: XCTestCase {

    // MARK: - Pure vector math

    func testCosineSimilarity() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1, accuracy: 1e-9)
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-9)
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([0, 0], [1, 1]), 0, "zero vector → 0, not a crash")
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 2], [1, 2, 3]), 0, "length mismatch → 0")
    }

    func testMeanPool() {
        XCTAssertEqual(EmbeddingMath.meanPool([[2, 4], [4, 8]])!, [3, 6])
        XCTAssertNil(EmbeddingMath.meanPool([]), "no tokens → nil")
        XCTAssertNil(EmbeddingMath.meanPool([[1, 2], [1, 2, 3]]), "ragged vectors → nil, never truncated")
    }

    // MARK: - Suggester

    private func candidate(_ id: Int64, _ name: String, _ vector: [Double], family: String? = nil) -> SemanticSuggester.Candidate {
        SemanticSuggester.Candidate(exerciseID: id, canonicalName: name, familyKey: family, vector: vector)
    }

    func testSemanticNearMissSurfacesASemanticSuggestion() {
        // "chest press" embeds near Bench Press / Chest Fly, far from Squat.
        let embedding = FakeEmbedding(vectors: ["chest press": [0.95, 0.05, 0.0]])
        let suggester = SemanticSuggester(embedding: embedding)
        let candidates = [
            candidate(1, "Bench Press", [1.0, 0.0, 0.0]),
            candidate(2, "Chest Fly", [0.9, 0.1, 0.0]),
            candidate(3, "Squat", [0.0, 1.0, 0.0])
        ]
        let suggestions = suggester.suggestions(for: "chest press", among: candidates)

        XCTAssertEqual(suggestions.first?.canonicalName, "Bench Press")
        XCTAssertTrue(suggestions.allSatisfy { $0.via == .semantic }, "Layer 3 marks its origin")
        XCTAssertFalse(suggestions.contains { $0.canonicalName == "Squat" }, "below-threshold is excluded")
        XCTAssertTrue(suggestions.allSatisfy { $0.score >= 0.80 })
    }

    func testNotReadyEmbeddingYieldsNoSuggestions() {
        // The shippable bar: when embeddings aren't ready, Layer 3 is silent and the
        // caller keeps whatever fuzzy/FM produced.
        let embedding = FakeEmbedding(ready: false, vectors: ["chest press": [1, 0, 0]])
        let suggester = SemanticSuggester(embedding: embedding)
        let candidates = [candidate(1, "Bench Press", [1, 0, 0])]
        XCTAssertTrue(suggester.suggestions(for: "chest press", among: candidates).isEmpty)
    }

    func testNoVectorForQueryYieldsNoSuggestions() {
        let embedding = FakeEmbedding(vectors: [:])   // ready, but no vector for the query
        let suggester = SemanticSuggester(embedding: embedding)
        let candidates = [candidate(1, "Bench Press", [1, 0, 0])]
        XCTAssertTrue(suggester.suggestions(for: "asdf", among: candidates).isEmpty)
    }

    func testRankingIsOrderedAndCapped() {
        let embedding = FakeEmbedding(vectors: ["q": [1.0, 0.0]])
        let suggester = SemanticSuggester(embedding: embedding)
        let candidates = [
            candidate(1, "Closest", [1.0, 0.0]),       // cos 1.0
            candidate(2, "Near", [0.99, 0.14]),        // ~0.99
            candidate(3, "Mid", [0.9, 0.44]),          // ~0.9
            candidate(4, "Far", [0.0, 1.0])            // 0 → excluded
        ]
        let suggestions = suggester.suggestions(for: "q", among: candidates, limit: 2)
        XCTAssertEqual(suggestions.map(\.canonicalName), ["Closest", "Near"], "best-first, capped at limit")
    }

    func testNoopEmbeddingIsNeverReady() {
        XCTAssertFalse(NoopEmbedding().isReady)
        XCTAssertNil(NoopEmbedding().vector(for: "anything"))
    }
}
