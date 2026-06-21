#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// Layer 3's real implementation (§1.1, "PR 7"): Apple's on-device
/// `NLContextualEmbedding` (BERT-style; model assets ship in the **system** catalog,
/// so zero app size). The entire file is wrapped in `#if canImport(NaturalLanguage)`
/// so not one `NLContextualEmbedding` symbol leaks into always-compiled code; callers
/// only ever see the `ExerciseEmbedding` protocol, and tests use a fake.
///
/// NOT COMPILED HERE (Linux, no NaturalLanguage SDK) and **NOT VERIFIED ON DEVICE.**
/// The assets download asynchronously and are documented to **fail to load in the
/// simulator**, so this is gated exactly like `FoundationWorkoutParser`: a compile
/// gate **and** a runtime load check, with any failure falling through to fuzzy/FM.
/// The exact symbol names / availability below must be verified in Xcode against the
/// installed SDK — the SDK is the source of truth, not this file.
@available(iOS 17.0, *)
final class NLContextualEmbeddingExerciseMatcher: ExerciseEmbedding {
    private let model: NLContextualEmbedding
    /// Whether `model.load()` has succeeded. **Not latched at init**: assets download
    /// asynchronously, so readiness is re-evaluated on demand (`ensureLoaded`) and can
    /// flip to true later in the same session once the download finishes — no view/
    /// model recreation required.
    private var loaded = false
    private var requestedAssets = false

    private init?(language: NLLanguage) {
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        self.model = model
        _ = ensureLoaded()   // load now if assets are already present; else kick off the request
    }

    /// Load the model if assets are present and it isn't loaded yet; otherwise kick off
    /// the async asset request (once) and report not-ready for now. Idempotent and
    /// non-blocking — it never waits on a download, so a not-ready return simply falls
    /// through to fuzzy/FM. `hasAvailableAssets` / `load()` / `requestAssets` are the
    /// documented entry points — verify exact spelling in Xcode.
    @discardableResult
    private func ensureLoaded() -> Bool {
        if loaded { return true }
        if model.hasAvailableAssets {
            loaded = (try? { try model.load(); return true }()) ?? false
        } else if !requestedAssets {
            requestedAssets = true
            model.requestAssets { _, _ in }   // ready flips on a later `ensureLoaded`
        }
        return loaded
    }

    /// Build a matcher only when the SDK reports a usable model on this OS; otherwise
    /// nil so the factory substitutes `NoopEmbedding`. English-only at launch (the
    /// seed/library is English); broadening is a later step.
    static func makeIfAvailable() -> NLContextualEmbeddingExerciseMatcher? {
        guard #available(iOS 17.0, *) else { return nil }
        return NLContextualEmbeddingExerciseMatcher(language: .english)
    }

    /// Re-checks readiness each call (re-attempting `load()` if assets have since
    /// arrived), so Layer 3 activates mid-session once the download completes.
    var isReady: Bool { ensureLoaded() }

    func vector(for text: String) -> [Double]? {
        guard ensureLoaded() else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let result = try model.embeddingResult(for: trimmed, language: .english)
            // Mean-pool the per-token vectors. Accelerate `vDSP` would speed this up on
            // device; the reference `EmbeddingMath.meanPool` keeps it correct + testable.
            var tokenVectors: [[Double]] = []
            // The closure's first parameter is `[Double]`. Append it
            // directly — the original `.map(Double.init)` was a no-op
            // identity transform that made the expression ambiguous
            // because `Double.init` has many overloads, none of which
            // the compiler could disambiguate without the explicit
            // closure parameter type that was missing.
            result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { (vector: [Double], _: Range<String.Index>) -> Bool in
                tokenVectors.append(vector)
                return true
            }
            return EmbeddingMath.meanPool(tokenVectors)
        } catch {
            return nil   // opportunistic: any failure → no semantic vector, fall through
        }
    }
}
#endif
