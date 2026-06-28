#if canImport(Vision)
import Foundation
import Vision
import os

/// The real on-device text recognizer (PR 14), entirely inside `#if canImport(Vision)`
/// so not one Vision symbol reaches always-compiled code. Conforms to the common
/// `TextRecognizing` protocol; the OCR model and tests only ever see that protocol.
///
/// On-device and private: `VNRecognizeTextRequest` runs locally; no image or recognized
/// text leaves the device. Accurate recognition with language correction — tuned for a
/// printed/handwritten workout sheet, where each physical line is one candidate set.
///
/// NOT COMPILED HERE (Linux, no Vision SDK). The symbol names below
/// (`VNRecognizeTextRequest`, `VNImageRequestHandler(data:)`, `.accurate`) are from the
/// spec/SDK docs and must be verified in Xcode.
struct VisionTextRecognizer: TextRecognizing {
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "WorkoutChatLog",
                             category: "OCR")

    func recognizeLines(in imageData: Data) async -> [RecognizedLine] {
        // `perform` is synchronous and CPU-heavy (accurate recognition over a full
        // image), so run it on a background task — the caller (`OCRCaptureModel`) is
        // `@MainActor`, and without this hop the work would block the main thread while
        // the sheet shows `.recognizing`. `Self.recognize` is `static` and `nonisolated`,
        // touching only its `Data`/`Logger` arguments, so it's safe off-main.
        let logger = log
        return await Task.detached(priority: .userInitiated) {
            Self.recognize(imageData: imageData, log: logger)
        }.value
    }

    private static func recognize(imageData: Data, log: Logger) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        // Printed sheets read best with language correction; accurate over fast because
        // correctness matters more than latency for a one-shot import.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(data: imageData, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // A recognition failure degrades to "no lines" (the UI then offers manual
            // entry); logged so a real failure is diagnosable, never a crash. The error
            // carries no user content.
            log.error("text recognition failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let observations = request.results ?? []
        return lines(from: observations)
    }

    /// Vision's normalized boxes are quantized into horizontal rows this tall (~3% of
    /// page height) so observations on the same physical line sort together regardless
    /// of sub-pixel `minY` jitter, then read left-to-right within the row.
    static let rowBandHeight = 0.03

    /// Map observations to lines in natural reading order. Vision's origin is
    /// bottom-left, so a higher `boundingBox.minY` is physically higher on the page.
    /// Sorting by `minY` descending *alone* misorders entries that share nearly the
    /// same Y (sub-pixel jitter) or sit in multiple columns — and `confirmAll()` later
    /// persists in this order. So quantize Y into row bands (top band first) and break
    /// ties left-to-right by `minX`. The comparator is a strict weak ordering over the
    /// derived `(band, minX)` key — no epsilon-compare transitivity trap. Each
    /// observation's top candidate is the line text; its confidence rides along for the
    /// low-confidence flag.
    ///
    /// (A single-column top-to-bottom sheet — the common case — is unaffected; the band
    /// + X tie-break only changes same-row / multi-column layouts, which remains a
    /// device-acceptance check.)
    static func lines(from observations: [VNRecognizedTextObservation]) -> [RecognizedLine] {
        func band(_ observation: VNRecognizedTextObservation) -> Int {
            Int((observation.boundingBox.minY / rowBandHeight).rounded(.down))
        }
        return observations
            .sorted { a, b in
                let bandA = band(a), bandB = band(b)
                if bandA != bandB { return bandA > bandB }       // higher band = higher on page, first
                return a.boundingBox.minX < b.boundingBox.minX   // same row: left-to-right
            }
            .compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return RecognizedLine(text: text, confidence: candidate.confidence)
            }
    }
}
#endif
