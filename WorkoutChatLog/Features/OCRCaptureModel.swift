import Foundation

/// One recognized line as a reviewable candidate entry (PR 14). It carries the raw
/// OCR text, an editable copy, the recognizer's confidence, and the parse result of
/// running the (editable) text through the **existing** parser. Nothing here is saved
/// until the user confirms.
struct OCRLineCandidate: Identifiable, Equatable {
    let id: UUID
    /// Exactly what OCR read — preserved so the user can see the original even after
    /// editing.
    let originalText: String
    /// The text actually parsed; starts equal to `originalText`, editable in review.
    var text: String
    /// Recognizer self-report (0…1). Drives the low-confidence flag; never invented.
    let confidence: Float
    /// Parsed sets from the deterministic→FM stack, or empty when the line couldn't be
    /// read as a set (then it's flagged for edit/skip, never silently saved).
    var sets: [SetDraft]
    /// Whether this line will be saved on confirm. Defaults on for a parsed line, off
    /// for an unreadable one — the user can flip either.
    var included: Bool
    /// True once the user has *explicitly* unchecked this line, so a later edit/reparse
    /// doesn't silently re-include something they chose to skip.
    var userExcluded: Bool = false
    /// True once the user has edited the text away from the OCR original. An edited line
    /// is the user's own typing, not a recognizer read, so the OCR `confidence` (and its
    /// low-confidence flag) no longer applies to it.
    var isEdited: Bool = false
    /// The exact `text` that `sets` was last parsed from. When this differs from the
    /// current `text`, an edit is pending a reparse (so the line is optimistically
    /// "will save, pending"); when it equals `text`, `sets` is authoritative — an empty
    /// `sets` then means *known* unreadable, not "not yet tried."
    var lastParsedText: String

    /// The line parsed into at least one set.
    var isParsed: Bool { !sets.isEmpty }

    /// There's an edit the parser hasn't seen yet — `sets` is stale, not authoritative.
    var hasPendingReparse: Bool { text != lastParsedText }
}

/// Drives OCR capture (PR 14): recognize an imported/photographed sheet → run each
/// line through the existing parser → present a review list → on confirm, append the
/// confirmed lines to **one** active session. **OCR is an input source, not a new
/// pipeline** — it reuses `WorkoutParsing` and `WorkoutStore.save`, adds no second
/// parser and no second validator, and **never auto-saves**.
///
/// `@MainActor` because it owns published UI state and calls the main-actor store; it
/// holds a `TextRecognizing` and a `WorkoutParsing` (both injectable) so the whole
/// flow is testable with a fake recognizer + fake parser, with no Vision import.
@MainActor
final class OCRCaptureModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recognizing
        case review            // candidates ready for confirm/edit/skip
        case empty             // recognized nothing (or recognition unavailable)
        case saved(Int)        // n sets written into one session
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidates: [OCRLineCandidate] = []
    /// True while a `confirmAll()` is in flight, so the UI can disable Save and a
    /// second tap can't kick off a duplicate write. `@MainActor` makes the
    /// check-and-set atomic.
    @Published private(set) var isSaving = false

    /// Monotonic token for the async recognize lifecycle. Picking a second image before
    /// the first finishes starts two overlapping `recognize` calls; each claims the next
    /// token and, on resume, applies its result only if it's still the latest — so an
    /// older image's OCR can't overwrite a newer pick. Mutated/read on the main actor
    /// (`@MainActor`), so the check is race-free. (Mirrors `TodayModel.parseGeneration`.)
    private var recognizeGeneration = 0

    /// Below this recognizer confidence a parsed line is still shown but flagged
    /// "review — OCR can misread." Printed text usually clears it; handwriting often
    /// doesn't. Tunable by hand.
    static let lowConfidenceThreshold: Float = 0.5

    private let store: WorkoutStore
    private let parser: WorkoutParsing
    private let recognizer: TextRecognizing

    init(store: WorkoutStore,
         parser: WorkoutParsing? = nil,
         recognizer: TextRecognizing? = nil) {
        self.store = store
        self.parser = parser ?? WorkoutParserFactory.make(store: store)
        self.recognizer = recognizer ?? TextRecognizerFactory.make()
    }

    /// A line whose recognizer confidence is below the bar — surface it for review.
    func isLowConfidence(_ candidate: OCRLineCandidate) -> Bool {
        // An edited line is the user's own text, so the OCR confidence no longer
        // applies — don't show a stale "low confidence" warning on it.
        !candidate.isEdited && candidate.confidence < Self.lowConfidenceThreshold
    }

    /// Whether this line will be persisted on confirm: not explicitly skipped, non-empty,
    /// and **either** it currently parses to sets **or** it has an edit the parser hasn't
    /// re-checked yet (optimistic — confirm reparses it). A line whose *current* text was
    /// already reparsed to no sets is **not** saveable, so a committed-yet-unreadable row
    /// shows unchecked and uncounted rather than being silently dropped at save. The row
    /// checkbox, the count, and `confirmAll`'s snapshot all read this one predicate.
    func willSave(_ candidate: OCRLineCandidate) -> Bool {
        guard !candidate.userExcluded,
              !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return candidate.isParsed || candidate.hasPendingReparse
    }

    /// How many lines will be persisted on confirm (the Save button count). Matches
    /// `confirmAll`'s predicate so the label can't undercount edited-but-uncommitted rows.
    var confirmableCount: Int {
        candidates.filter(willSave).count
    }

    /// The Save button is enabled when at least one line will save.
    var canConfirm: Bool {
        candidates.contains(where: willSave)
    }

    /// Recognize an image's text and build the review list. Each line is parsed through
    /// the existing stack; an unreadable line becomes a flagged, skip-by-default
    /// candidate rather than being dropped. **Latest-request-wins:** if a newer image is
    /// picked before this finishes, this call's results are discarded on resume so a
    /// slower older OCR can't overwrite the newer pick.
    func recognize(imageData: Data) async {
        recognizeGeneration += 1
        let generation = recognizeGeneration
        phase = .recognizing
        candidates = []

        let lines = await recognizer.recognizeLines(in: imageData)
        guard generation == recognizeGeneration else { return }   // superseded by a newer pick
        guard !lines.isEmpty else {
            phase = .empty
            return
        }
        var built: [OCRLineCandidate] = []
        for line in lines {
            let sets = await parsedSets(for: line.text)
            guard generation == recognizeGeneration else { return }   // superseded mid-parse
            built.append(OCRLineCandidate(id: UUID(),
                                          originalText: line.text,
                                          text: line.text,
                                          confidence: line.confidence,
                                          sets: sets,
                                          included: !sets.isEmpty,
                                          lastParsedText: line.text))
        }
        guard generation == recognizeGeneration else { return }
        candidates = built
        phase = .review
    }

    /// Keep `text` in sync with the field on every keystroke (no parse — cheap). The
    /// authoritative re-parse happens in `commitEdit`/`confirmAll`, so what's saved can
    /// never lag what's on screen even if the user never presses return.
    func setText(_ id: UUID, _ newText: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].text = newText
        // Mark as the user's own text once it diverges from the OCR original, so Save
        // can enable for a fixed-but-uncommitted line and the stale OCR confidence flag
        // drops off.
        candidates[index].isEdited = (newText != candidates[index].originalText)
    }

    /// Re-parse a candidate after an edit (on field commit / focus loss) to refresh its
    /// shown sets/inclusion. `setText` is the single source of truth for `text` — this
    /// does **not** write `text`, so a slow/older commit can't make its own stale text
    /// "current." It parses the row's *current* text and applies the result only if the
    /// text hasn't changed since (an out-of-order or superseded parse is dropped). A line
    /// the user explicitly unchecked stays excluded even if it now parses.
    ///
    /// (`confirmAll` re-parses current text again at save time, so display freshness here
    /// is a UX nicety; the saved data is correct regardless.)
    func commitEdit(_ id: UUID) async {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        let parsedText = candidates[index].text
        let sets = await parsedSets(for: parsedText)
        guard let now = candidates.firstIndex(where: { $0.id == id }),
              candidates[now].text == parsedText else { return }   // text moved on — discard this parse
        candidates[now].sets = sets
        candidates[now].lastParsedText = parsedText   // `sets` is now authoritative for this text
        candidates[now].included = !sets.isEmpty && !candidates[now].userExcluded
    }

    /// Toggle whether a line is included in the save. `userExcluded` is the source of
    /// truth `willSave` consults, so an explicit uncheck sticks across later edits/
    /// reparses; re-checking clears it. (`included` is kept in sync for display.)
    func setIncluded(_ id: UUID, _ included: Bool) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].userExcluded = !included
        candidates[index].included = included && candidates[index].isParsed
    }

    /// Write every included line into **one** session, continuing `set_index`.
    /// **Re-parses each line from its current `text` first**, so the saved draft always
    /// matches the latest visible text even if an edit was never submitted (the row's
    /// `setText` keeps `text` live). All-or-nothing in one transaction; nothing was
    /// written before this call; unreadable/excluded lines are never saved.
    func confirmAll() async {
        // Single-flight: a double-tap (or a tap during a slow reparse) must not run a
        // second save and append duplicate sets. `@MainActor` makes this guard atomic.
        // The view also disables the rows + "Start over" while `isSaving`, but the
        // snapshot below is the real guarantee.
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        // Snapshot the full save input — `(id, text)` of every line that `willSave`
        // (checkbox on) — **before** any await. The entire save is built from this
        // immutable snapshot; the live `candidates` array is never read for the write,
        // so an edit or "Start over" arriving mid-await can't change or crash the save.
        // This is exactly the set the UI shows as included, so what saves == what's checked.
        let snapshot = candidates.filter(willSave).map { (id: $0.id, text: $0.text) }

        var draftSets: [SetDraft] = []
        var unreadable = 0   // checked lines that reparsed to nothing at confirm time
        for line in snapshot {
            let parsed = await parsedSets(for: line.text)
            // Mirror the reparse onto the live row (best-effort, nil-safe). Recording
            // `lastParsedText` makes a now-empty row drop out of `willSave` so it shows
            // unchecked instead of a phantom check.
            if let index = candidates.firstIndex(where: { $0.id == line.id }) {
                candidates[index].sets = parsed
                candidates[index].lastParsedText = line.text
                candidates[index].included = !parsed.isEmpty
            }
            if parsed.isEmpty { unreadable += 1 }
            for set in parsed {
                var copy = set
                // Provenance: the text these sets were parsed from (the user's
                // correction if edited), so a fixed line doesn't carry the OCR misread.
                copy.sourceText = copy.sourceText ?? line.text
                draftSets.append(copy)
            }
        }

        // Never silently drop a line the user had checked. If any checked line turned
        // out unreadable at confirm, save nothing and bounce back to review with it now
        // visibly unchecked (its `lastParsedText` was recorded above) — the user fixes
        // or skips it and re-confirms. (All-or-nothing keeps "what you saw == what saved".)
        guard unreadable == 0 else {
            phase = .failed(unreadable == snapshot.count
                ? "Couldn't read any sets to save. Fix a line, then try again."
                : "\(unreadable) line\(unreadable == 1 ? "" : "s") couldn't be read. Fix or uncheck \(unreadable == 1 ? "it" : "them"), then save.")
            return
        }
        guard !draftSets.isEmpty else {
            phase = .failed("Couldn't read any sets to save. Fix a line, then try again.")
            return
        }
        do {
            let draft = WorkoutDraft(startedAt: Date(), name: nil, notes: nil, sets: draftSets)
            // `into: nil` reuses the active (open) session or lazily opens one, so the
            // confirmed lines append to the same session the Today tab shows, with
            // set_index continued from MAX+1.
            let result = try store.save(draft, into: nil)
            phase = .saved(result.setIDs.count)
            candidates = []
        } catch {
            phase = .failed(TodayModel.message(for: error))
        }
    }

    /// Surfaced when an imported photo can't be loaded/decoded, so a failed pick reads
    /// as an honest error rather than a silent no-op.
    func imageLoadFailed() {
        phase = .failed("Couldn't load that image. Try another photo.")
    }

    /// Return to the review list after a failed confirm (the candidates are kept on
    /// failure, so the user can adjust and retry without re-scanning).
    func backToReview() {
        if !candidates.isEmpty { phase = .review }
    }

    /// Discard the review list and return to the start (e.g. to pick another image).
    func reset() {
        candidates = []
        phase = .idle
    }

    private func parsedSets(for text: String) async -> [SetDraft] {
        // OCR is non-interactive per line, so a clarification or decline both mean
        // "couldn't read this line" — flag it for manual edit, never guess.
        switch await parser.parse(text, context: []) {
        case .draft(let result):
            // A sheet line must name its exercise. A bare scheme ("3x10") parses to a
            // nameless draft that couldn't be saved anyway, so treat it as unreadable
            // and flag it for editing rather than failing at confirm.
            let named = result.sets.allSatisfy { !$0.exerciseName.trimmingCharacters(in: .whitespaces).isEmpty }
            return named ? result.sets : []
        case .clarification, .declined(_):
            return []
        }
    }
}
