import XCTest
@testable import WorkoutChatLog

/// A scripted `TextRecognizing` for the PR 14 tests — **no Vision import**. It ignores
/// the image bytes and returns the lines the test supplies, so the OCR flow (recognize
/// → parse each line → review → confirm-append) is exercised end-to-end without a
/// camera, an image, or the Vision SDK.
private struct FakeTextRecognizer: TextRecognizing {
    let lines: [RecognizedLine]
    func recognizeLines(in imageData: Data) async -> [RecognizedLine] { lines }

    static func of(_ texts: [String], confidence: Float = 0.95) -> FakeTextRecognizer {
        FakeTextRecognizer(lines: texts.map { RecognizedLine(text: $0, confidence: confidence) })
    }
}

/// A `WorkoutParsing` whose every call suspends until the test resumes it, so two
/// overlapping `commitEdit` parses can be completed **out of order** — the real race
/// the stale-parse guard defends against. An `actor` for Sendable-safe bookkeeping.
private actor GatedParser: WorkoutParsing {
    private var continuations: [CheckedContinuation<ParseOutcome, Never>] = []
    private(set) var requestedInputs: [String] = []

    var count: Int { continuations.count }

    func parse(_ input: String, context: [String]) async -> ParseOutcome {
        await withCheckedContinuation { continuation in
            requestedInputs.append(input)
            continuations.append(continuation)
        }
    }

    /// Resume the Nth started parse with a draft of one bench set at `reps` (or decline).
    func resume(_ index: Int, reps: Int?) {
        if let reps {
            let set = SetDraft(exerciseName: "Bench Press", weight: 135, unit: .lb,
                               loadKind: .external, reps: reps)
            continuations[index].resume(returning: .draft(WorkoutParseResult(sets: [set], source: .deterministic)))
        } else {
            continuations[index].resume(returning: .declined)
        }
    }
}

@MainActor
final class OCRCaptureModelTests: XCTestCase {

    private var path: String!
    private var store: WorkoutStore!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "wcl-ocr-\(UUID().uuidString).sqlite"
        store = WorkoutStore(db: try SQLiteDB(path: path))
        try store.migrate()
        try store.seedExercisesIfNeeded(ExerciseSeed.load(from: Bundle(for: Self.self)))
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// The real deterministic layer (FM is unavailable here) — OCR routes lines through
    /// the *same* parser the typed flow uses, not a second pipeline. Takes the concrete
    /// `FakeTextRecognizer` so call sites can use the `.of(...)` leading-dot helper
    /// (which a protocol-typed parameter wouldn't resolve).
    private func makeModel(_ recognizer: FakeTextRecognizer) -> OCRCaptureModel {
        OCRCaptureModel(store: store,
                        parser: WorkoutParserOrchestrator(deterministic: DeterministicWorkoutParsing(),
                                                          foundation: nil),
                        recognizer: recognizer)
    }

    private let blankData = Data()

    // MARK: - Recognition → review list

    func testLatestImagePickWinsWhenOCRCompletesOutOfOrder() async {
        // Pick image A, then image B before A finishes; B's parse completes first, then
        // A's. The recognize-generation guard must discard A's stale result so the review
        // list shows B's line, not A's.
        let gated = GatedParser()
        let model = OCRCaptureModel(store: store, parser: gated,
                                    recognizer: FakeTextRecognizer.of(["bench 135x8"]))
        // First import (A) — suspends on its parse (gate 0).
        async let importA: Void = model.recognize(imageData: Data([0x41]))
        while await gated.count < 1 { await Task.yield() }

        // Second import (B) starts before A finishes — suspends on its parse (gate 1).
        async let importB: Void = model.recognize(imageData: Data([0x42]))
        while await gated.count < 2 { await Task.yield() }

        // B finishes first (its line parses to squat), then A (bench) — out of order.
        await gated.resume(1, reps: 5)   // B
        await importB
        await gated.resume(0, reps: 8)   // A — stale, must be discarded
        await importA

        // The fake recognizer returns "bench 135x8" for both, so assert via the parsed
        // reps: B resumed with 5, A with 8. Latest pick (B) must win.
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertEqual(model.candidates[0].sets.first?.reps, 5,
                       "the newer pick's OCR result stands; the stale older one is discarded")
    }

    func testMultiLineProducesACandidatePerLine() async {
        let model = makeModel(.of(["bench 135x8", "squat 225x5", "had a great day"]))
        await model.recognize(imageData: blankData)

        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.candidates.count, 3, "one candidate per recognized line")
        XCTAssertTrue(model.candidates[0].isParsed)   // bench
        XCTAssertTrue(model.candidates[1].isParsed)   // squat
        XCTAssertFalse(model.candidates[2].isParsed, "prose isn't a set — flagged, not parsed")
    }

    func testEmptyRecognitionGoesToEmptyPhaseNotReview() async {
        let model = makeModel(.of([]))
        await model.recognize(imageData: blankData)
        XCTAssertEqual(model.phase, .empty)
        XCTAssertTrue(model.candidates.isEmpty)
    }

    func testBareSchemeWithoutExerciseIsTreatedAsUnreadable() async {
        // "3x10" parses to a nameless draft that couldn't be saved — flag for editing.
        let model = makeModel(.of(["3x10"]))
        await model.recognize(imageData: blankData)
        XCTAssertFalse(model.candidates[0].isParsed)
        XCTAssertFalse(model.canConfirm)
    }

    func testLowConfidenceLineIsFlaggedEvenWhenParsed() async {
        let model = makeModel(FakeTextRecognizer(lines: [RecognizedLine(text: "bench 135x8", confidence: 0.3)]))
        await model.recognize(imageData: blankData)
        XCTAssertTrue(model.candidates[0].isParsed)
        XCTAssertTrue(model.isLowConfidence(model.candidates[0]), "a parsed but low-confidence line still asks for review")
    }

    // MARK: - Nothing persists before confirm

    func testNothingPersistsBeforeConfirm() async throws {
        let model = makeModel(.of(["bench 135x8", "squat 225x5"]))
        await model.recognize(imageData: blankData)
        XCTAssertEqual(try store.setCount(), 0, "recognition + parsing never writes")
    }

    // MARK: - Confirm → one session

    func testConfirmAppendsAllLinesToOneSessionWithContinuedIndex() async throws {
        let model = makeModel(.of(["bench 135 for 8,8", "squat 225x5"]))   // 2 sets + 1 set
        await model.recognize(imageData: blankData)
        await model.confirmAll()

        XCTAssertEqual(model.phase, .saved(3), "2 bench sets + 1 squat set")
        XCTAssertEqual(try store.sessionCount(), 1, "all confirmed lines land in one session")
        XCTAssertEqual(try store.setCount(), 3)
        let rows = try store.sets(inSession: 1)
        XCTAssertEqual(rows.map(\.setIndex), [1, 2, 3], "set_index continues across lines")
    }

    func testUnparseableLineIsFlaggedAndNotSaved() async throws {
        let model = makeModel(.of(["bench 135x8", "totally unreadable scribble"]))
        await model.recognize(imageData: blankData)

        XCTAssertEqual(model.confirmableCount, 1, "only the parsed line is confirmable")
        await model.confirmAll()
        XCTAssertEqual(try store.setCount(), 1, "the unreadable line was never saved")
    }

    func testConfirmedLinesAppendToAnExistingOpenSession() async throws {
        // Simulate an in-progress workout, then OCR a sheet: its lines append to that
        // same session rather than opening a new one.
        _ = try store.save(WorkoutDraft(startedAt: Date(), name: nil, notes: nil,
                                        sets: [SetDraft(exerciseName: "Bench Press", weight: 135, unit: .lb,
                                                        loadKind: .external, reps: 8)]), into: nil)
        let model = makeModel(.of(["squat 225x5"]))
        await model.recognize(imageData: blankData)
        await model.confirmAll()

        XCTAssertEqual(try store.sessionCount(), 1, "OCR appended to the open session")
        XCTAssertEqual(try store.setCount(), 2)
    }

    // MARK: - Editing

    func testEditingALineReparsesIt() async {
        let model = makeModel(.of(["bench onehundred"]))   // unreadable as written
        await model.recognize(imageData: blankData)
        XCTAssertFalse(model.candidates[0].isParsed)

        model.setText(model.candidates[0].id, "bench 135x8")
        await model.commitEdit(model.candidates[0].id)
        XCTAssertTrue(model.candidates[0].isParsed, "fixing the text re-parses and enables it")
        XCTAssertTrue(model.candidates[0].included)
    }

    func testUncommittedEditIsReflectedAtConfirm() async throws {
        // The user types a correction but never presses return / loses focus; setText
        // keeps the model's text live, and confirmAll re-parses from it, so the
        // *corrected* line is saved — never the stale OCR parse — even though it was
        // unreadable (included == false) when scanned.
        let model = makeModel(.of(["bench onehundred"]))   // unreadable as scanned
        await model.recognize(imageData: blankData)
        XCTAssertFalse(model.candidates[0].isParsed)

        model.setText(model.candidates[0].id, "bench 135x8")   // live keystroke sync, no parse yet
        XCTAssertTrue(model.canConfirm, "a fixed-but-uncommitted line still enables Save")
        await model.confirmAll()

        XCTAssertEqual(try store.setCount(), 1, "confirm re-parsed the corrected text and saved it")
        XCTAssertEqual(model.phase, .saved(1))
    }

    func testEditedIntoUnreadableIsNotSavedAtConfirm() async throws {
        // A line that parsed when scanned but was edited into garbage (without
        // committing) must not save a stale valid parse.
        let model = makeModel(.of(["bench 135x8"]))
        await model.recognize(imageData: blankData)
        XCTAssertTrue(model.candidates[0].included)

        model.setText(model.candidates[0].id, "bench onehundred")   // now unreadable
        await model.confirmAll()

        XCTAssertEqual(try store.setCount(), 0, "the stale valid parse is not saved over an unreadable edit")
    }

    func testExplicitUncheckSurvivesAReparse() async {
        let model = makeModel(.of(["bench 135x8"]))
        await model.recognize(imageData: blankData)
        model.setIncluded(model.candidates[0].id, false)   // user explicitly skips it

        model.setText(model.candidates[0].id, "bench 145x6")   // edits it (still valid)
        await model.commitEdit(model.candidates[0].id)
        XCTAssertFalse(model.candidates[0].included, "an explicitly skipped line stays skipped after an edit")
    }

    func testOutOfOrderCommitDoesNotOverwriteNewerEdit() async {
        // A true race: two commits overlap and the OLDER one's parse completes LAST.
        // The guard (apply only if the row's text still matches what was parsed) must
        // drop the stale result so the newer edit's parse stands.
        let gated = GatedParser()
        let model = OCRCaptureModel(store: store, parser: gated,
                                    recognizer: FakeTextRecognizer.of(["bench original"]))

        // recognize() makes one gated parse for the line; resume it as unreadable so a
        // single review candidate is created.
        async let recognized: Void = model.recognize(imageData: blankData)
        while await gated.count < 1 { await Task.yield() }
        await gated.resume(0, reps: nil)        // line is unreadable on scan
        await recognized
        let id = model.candidates[0].id

        // First edit + commit (would parse to 8 reps); it suspends on the gate.
        model.setText(id, "bench 135x8")
        async let firstCommit: Void = model.commitEdit(id)
        while await gated.count < 2 { await Task.yield() }

        // Second edit + commit (would parse to 6 reps); it suspends too.
        model.setText(id, "bench 145x6")
        async let secondCommit: Void = model.commitEdit(id)
        while await gated.count < 3 { await Task.yield() }

        // Resume the NEWER parse first (reps 6), then the OLDER one (reps 8) LAST.
        await gated.resume(2, reps: 6)
        await gated.resume(1, reps: 8)
        _ = await (firstCommit, secondCommit)

        // The first commit parsed "bench 135x8" but the row text is now "bench 145x6",
        // so its stale result is dropped; the newer parse (6) stands.
        XCTAssertEqual(model.candidates[0].sets.first?.reps, 6,
                       "the stale older parse must not overwrite the newer edit's result")
    }

    // MARK: - Save-enable semantics

    func testSaveDisabledForUntouchedUnreadableScanButEnabledAfterEdit() async {
        let model = makeModel(.of(["3x10"]))   // parses to a nameless (unsavable) draft
        await model.recognize(imageData: blankData)
        XCTAssertFalse(model.canConfirm, "an untouched unreadable scan must not enable Save")

        model.setText(model.candidates[0].id, "squat 225x5")   // user fixes it
        XCTAssertTrue(model.canConfirm, "editing it enables Save (confirm will re-parse)")
    }

    func testWillSaveAndCountMatchEditedUncommittedRows() async {
        // The checkbox/label read `willSave`/`confirmableCount`, which must agree with
        // what confirmAll persists — including a fixed-but-uncommitted line (counted) and
        // an untouched unreadable scan (not counted).
        let model = makeModel(.of(["bench 135x8", "squat scribble"]))
        await model.recognize(imageData: blankData)
        XCTAssertTrue(model.willSave(model.candidates[0]), "the parsed line shows checked")
        XCTAssertFalse(model.willSave(model.candidates[1]), "the unreadable scan shows unchecked")
        XCTAssertEqual(model.confirmableCount, 1)

        model.setText(model.candidates[1].id, "squat 225x5")   // fix it, no commit
        XCTAssertTrue(model.willSave(model.candidates[1]), "the edited line now shows checked")
        XCTAssertEqual(model.confirmableCount, 2, "the label counts both, matching confirmAll")
    }

    func testCommittedStillUnreadableRowDropsOutOfWillSave() async {
        // After an edit is committed and STILL doesn't parse, the row must not keep a
        // phantom check: willSave consults lastParsedText, so a committed-empty row reads
        // as not-saveable (vs. an edit pending reparse, which is optimistically checked).
        let model = makeModel(.of(["squat scribble"]))
        await model.recognize(imageData: blankData)
        model.setText(model.candidates[0].id, "still not a set")
        XCTAssertTrue(model.willSave(model.candidates[0]), "pending reparse → optimistically checked")

        await model.commitEdit(model.candidates[0].id)   // reparses; still empty
        XCTAssertFalse(model.willSave(model.candidates[0]), "committed-yet-unreadable → unchecked")
        XCTAssertEqual(model.confirmableCount, 0)
    }

    func testMixedSaveNeverSilentlyDropsACheckedLine() async throws {
        // One valid line + one edited-then-committed-still-unreadable line. The unreadable
        // one is already dropped from willSave by the test above; but if a line is checked
        // (pending reparse) and turns out unreadable at confirm, confirmAll must NOT save
        // the rest silently — it stops and reports, saving nothing.
        let model = makeModel(.of(["bench 135x8", "squat scribble"]))
        await model.recognize(imageData: blankData)
        model.setText(model.candidates[1].id, "still not a set")   // pending reparse → checked
        XCTAssertEqual(model.confirmableCount, 2, "both look checked before confirm reparses")

        await model.confirmAll()

        XCTAssertEqual(try store.setCount(), 0, "all-or-nothing: a checked line that won't read blocks the save")
        guard case .failed = model.phase else {
            return XCTFail("a checked-but-unreadable line must surface a warning, not be silently dropped")
        }
        // The unreadable row is now committed-empty, so a second confirm (after the user
        // unchecks/fixes) would proceed. Here, unchecking it lets the valid line save.
        model.setIncluded(model.candidates[1].id, false)
        await model.confirmAll()
        XCTAssertEqual(try store.setCount(), 1, "with the bad line skipped, the valid line saves")
    }

    func testConfirmWithNothingParseableSurfacesAnErrorNotASilentNoOp() async throws {
        let model = makeModel(.of(["bench 135x8"]))
        await model.recognize(imageData: blankData)
        model.setText(model.candidates[0].id, "still not a set")   // edited into garbage
        XCTAssertTrue(model.canConfirm, "edited line keeps Save enabled")

        await model.confirmAll()
        XCTAssertEqual(try store.setCount(), 0)
        guard case .failed = model.phase else {
            return XCTFail("confirm that parses to nothing must surface an error, not no-op")
        }
    }

    func testEditedLineDropsTheLowConfidenceFlag() async {
        let model = makeModel(FakeTextRecognizer(lines: [RecognizedLine(text: "bench 135x8", confidence: 0.2)]))
        await model.recognize(imageData: blankData)
        XCTAssertTrue(model.isLowConfidence(model.candidates[0]))

        model.setText(model.candidates[0].id, "bench 145x6")   // user's own text now
        XCTAssertFalse(model.isLowConfidence(model.candidates[0]),
                       "the OCR confidence no longer applies once the user edited the line")
    }

    func testEditedLineSavesCorrectedSourceText() async throws {
        let model = makeModel(.of(["bench onehundred"]))
        await model.recognize(imageData: blankData)
        model.setText(model.candidates[0].id, "bench 135x8")
        await model.commitEdit(model.candidates[0].id)
        await model.confirmAll()

        let rows = try store.sets(inSession: 1)
        XCTAssertEqual(rows.first?.sourceText, "bench 135x8",
                       "the saved set carries the corrected text, not the raw OCR misread")
    }

    func testConcurrentConfirmDoesNotDoubleSave() async throws {
        // A double-tap (or a tap while a slow reparse is in flight) must append once,
        // not twice. The GatedParser lets the first confirmAll suspend on its reparse
        // while a second confirmAll is launched; the single-flight guard makes the
        // second a no-op.
        let gated = GatedParser()
        let model = OCRCaptureModel(store: store, parser: gated,
                                    recognizer: FakeTextRecognizer.of(["bench 135x8"]))

        // recognize() parses the line once (gate index 0) → resume as a valid set so it
        // starts included.
        async let recognized: Void = model.recognize(imageData: blankData)
        while await gated.count < 1 { await Task.yield() }
        await gated.resume(0, reps: 8)
        await recognized
        XCTAssertTrue(model.candidates[0].included)

        // First confirmAll suspends on its reparse (gate index 1).
        async let first: Void = model.confirmAll()
        while await gated.count < 2 { await Task.yield() }
        XCTAssertTrue(model.isSaving, "first save is in flight")

        // Second confirmAll while the first is mid-flight: guarded out, no new parse.
        await model.confirmAll()
        let afterSecond = await gated.count
        XCTAssertEqual(afterSecond, 2, "the guarded second confirm started no new parse")

        // Let the first finish.
        await gated.resume(1, reps: 8)
        await first

        XCTAssertEqual(try store.setCount(), 1, "exactly one set saved despite two confirm taps")
        XCTAssertFalse(model.isSaving)
    }

    func testResetDuringConfirmDoesNotCrashAndSavesTheSnapshot() async throws {
        // "Start over" (reset) while confirmAll is suspended on a reparse must not crash
        // (out-of-range into a cleared candidates array). confirmAll works off a
        // snapshot taken before the await, so the save still reflects what was on screen
        // when Save was tapped.
        let gated = GatedParser()
        let model = OCRCaptureModel(store: store, parser: gated,
                                    recognizer: FakeTextRecognizer.of(["bench 135x8"]))
        async let recognized: Void = model.recognize(imageData: blankData)
        while await gated.count < 1 { await Task.yield() }
        await gated.resume(0, reps: 8)
        await recognized

        async let confirm: Void = model.confirmAll()
        while await gated.count < 2 { await Task.yield() }   // suspended on the reparse
        model.reset()                                        // clears candidates mid-save
        await gated.resume(1, reps: 8)
        await confirm                                        // must not crash

        XCTAssertEqual(try store.setCount(), 1, "the snapshot's set is saved despite the reset")
    }

    func testEditDuringConfirmDoesNotChangeWhatIsSaved() async throws {
        // A row edited while confirmAll is suspended must not change the saved data —
        // the save uses the snapshot text captured when Save was tapped.
        let gated = GatedParser()
        let model = OCRCaptureModel(store: store, parser: gated,
                                    recognizer: FakeTextRecognizer.of(["bench 135x8"]))
        async let recognized: Void = model.recognize(imageData: blankData)
        while await gated.count < 1 { await Task.yield() }
        await gated.resume(0, reps: 8)
        await recognized
        let id = model.candidates[0].id

        async let confirm: Void = model.confirmAll()
        while await gated.count < 2 { await Task.yield() }   // suspended reparsing snapshot text
        model.setText(id, "squat 225x5")                     // late edit — must not affect this save
        await gated.resume(1, reps: 8)                        // snapshot parse yields the bench set
        await confirm

        XCTAssertEqual(try store.setCount(), 1)
        let rows = try store.sets(inSession: 1)
        let exercise = try store.exercise(id: try XCTUnwrap(rows.first?.exerciseID))
        XCTAssertEqual(exercise?.canonicalName, "Bench Press",
                       "the save used the snapshot text, not the mid-save edit")
    }

    // MARK: - Inclusion

    func testCannotIncludeAnUnreadableLine() async {
        let model = makeModel(.of(["had a great day"]))
        await model.recognize(imageData: blankData)
        model.setIncluded(model.candidates[0].id, true)
        XCTAssertFalse(model.candidates[0].included, "a line with no parsed sets can't be force-included")
    }

    func testExcludingALineKeepsItOutOfTheSave() async throws {
        let model = makeModel(.of(["bench 135x8", "squat 225x5"]))
        await model.recognize(imageData: blankData)
        model.setIncluded(model.candidates[1].id, false)   // skip squat
        await model.confirmAll()

        XCTAssertEqual(try store.setCount(), 1, "only the included line was saved")
    }

    func testFixingAnUnreadableLineIncludesItAndConfirmSaysSo() async throws {
        // The contract: "only checked lines are saved." Fixing an unreadable line
        // includes it (its checkbox flips on), and confirm saves exactly the checked
        // lines — predicate and UI agree.
        let model = makeModel(.of(["squat scribble"]))
        await model.recognize(imageData: blankData)
        XCTAssertFalse(model.candidates[0].included, "unreadable scan starts unchecked/skipped")

        model.setText(model.candidates[0].id, "squat 225x5")
        await model.confirmAll()

        XCTAssertEqual(try store.setCount(), 1, "the fixed line was included and saved")
    }

    func testExplicitlyUncheckedValidLineIsNotSavedEvenThoughItParses() async throws {
        // A parsed line the user unchecks must stay out, even though confirm re-parses
        // (the re-parse must not silently re-include an explicitly-excluded row).
        let model = makeModel(.of(["bench 135x8"]))
        await model.recognize(imageData: blankData)
        model.setIncluded(model.candidates[0].id, false)
        await model.confirmAll()

        XCTAssertEqual(try store.setCount(), 0, "an explicitly unchecked line is never saved")
        guard case .failed = model.phase else {
            return XCTFail("nothing checked → confirm surfaces the empty state")
        }
    }

    // MARK: - Failure surfacing

    func testImageLoadFailureSurfacesAnError() {
        let model = makeModel(.of([]))
        model.imageLoadFailed()
        guard case .failed = model.phase else { return XCTFail("a load failure should be a visible error") }
    }
}
