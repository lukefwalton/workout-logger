import Foundation

/// One line of text recognized from an image, with the recognizer's own confidence
/// (0…1). `confidence` drives the "low-confidence — review this" flag in the OCR
/// review list; it is the recognizer's self-report, never a fabricated certainty.
struct RecognizedLine: Equatable {
    let text: String
    let confidence: Float
}

/// The seam between OCR capture and the on-device text recognizer (PR 14). Foundation
/// only — **no `Vision` symbol appears here** — so this protocol, the OCR model, and
/// the tests compile and run whether or not Vision is available. The gated
/// `VisionTextRecognizer` is the real implementation; tests drive a fake.
///
/// OCR is an *input source, not a new pipeline* (§"PR 14"): recognized lines feed the
/// existing deterministic → fuzzy → LLM → confirm → write path. The recognizer only
/// reads pixels into text; it never parses a workout and never writes anything.
///
/// `imageData` is encoded image bytes (JPEG/PNG/HEIC) — keeping the boundary at `Data`
/// means common code needs no `UIImage`/`CGImage`/`Vision` type, and the fake can
/// ignore the bytes entirely.
protocol TextRecognizing {
    /// Recognize text, returning one entry per line in natural reading order
    /// (top-to-bottom). Returns `[]` when nothing is found or recognition is
    /// unavailable — never throws into the UI; an empty result is the honest signal.
    func recognizeLines(in imageData: Data) async -> [RecognizedLine]
}

/// The stand-in used when Vision isn't compiled in (Linux/CI) or unavailable at
/// runtime: it recognizes nothing, so the OCR flow degrades to "couldn't read this
/// image — type it manually" rather than crashing.
struct NoopTextRecognizer: TextRecognizing {
    func recognizeLines(in imageData: Data) async -> [RecognizedLine] { [] }
}

/// Picks the real recognizer when the SDK is present, the no-op otherwise. The `#if`
/// is the only place the two worlds meet; callers just get a `TextRecognizing`.
enum TextRecognizerFactory {
    static func make() -> TextRecognizing {
        #if canImport(Vision)
        return VisionTextRecognizer()
        #else
        return NoopTextRecognizer()
        #endif
    }
}
