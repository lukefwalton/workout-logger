import SwiftUI
import PhotosUI

/// OCR capture (PR 14): import or photograph a workout sheet → review the recognized
/// lines → confirm to append them to the active session. Logic lives in
/// `OCRCaptureModel`; this view is thin glue. **Confirm-everything-before-write** — the
/// review list is the safety net, and the framing is honest: printed text is reliable,
/// handwriting is not.
///
/// NOTE: written correctly-by-inspection — not run in a simulator here; first real
/// verification is an Xcode/device launch (Vision + camera are device-only).
struct OCRCaptureView: View {
    @StateObject private var model: OCRCaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var showingCamera = false

    init(store: WorkoutStore) {
        _model = StateObject(wrappedValue: OCRCaptureModel(store: store))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan a workout")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .background(Theme.paper.ignoresSafeArea())
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            sourcePicker
        case .recognizing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading the sheet…").font(.footnote).foregroundStyle(Theme.steel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            emptyState
        case .review:
            reviewList
        case .saved(let count):
            savedState(count)
        case .failed(let message):
            failedState(message)
        }
    }

    // MARK: - Source selection

    private var sourcePicker: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(Theme.ocean)
            Text("Import a photo of a written or printed workout, and the app will read each line for you to review.")
                .font(.subheadline)
                .foregroundStyle(Theme.steel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose a photo", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            #if canImport(UIKit)
            if OCRCamera.isAvailable {
                Button {
                    showingCamera = true
                } label: {
                    Label("Use camera", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            #endif

            Text("On-device only — the image and text never leave your phone. OCR can misread, so you confirm every line before it's saved.")
                .font(.caption2)
                .foregroundStyle(Theme.steel)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                // A failed/undecodable transfer becomes a visible error, not a silent
                // no-op that looks like the tap was ignored.
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        await model.recognize(imageData: data)
                    } else {
                        model.imageLoadFailed()
                    }
                } catch {
                    model.imageLoadFailed()
                }
                // Clear the selection so re-picking the same asset (e.g. after Start
                // over) reliably re-fires onChange. recognize() is latest-request-wins,
                // so a quick A→B switch shows B's results regardless of completion order.
                photoItem = nil
            }
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showingCamera) {
            OCRCamera { data in
                showingCamera = false
                if let data { Task { await model.recognize(imageData: data) } }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    // MARK: - Review

    private var reviewList: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(model.candidates) { candidate in
                        OCRCandidateRow(
                            candidate: candidate,
                            willSave: model.willSave(candidate),
                            lowConfidence: model.isLowConfidence(candidate),
                            onTextChange: { newText in model.setText(candidate.id, newText) },
                            onCommit: { await model.commitEdit(candidate.id) },
                            onToggleInclude: { model.setIncluded(candidate.id, !model.willSave(candidate)) })
                    }
                } header: {
                    Text("Review — OCR can misread. Checked lines save; uncheck to skip. Fix a flagged line and it'll be included.")
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            // Lock the rows (edit/toggle) while a save is in flight so the review list
            // can't be mutated mid-save. confirmAll also snapshots, so this is the
            // belt to that suspenders.
            .disabled(model.isSaving)

            confirmBar
        }
    }

    private var confirmBar: some View {
        VStack(spacing: 8) {
            Button {
                Task { await model.confirmAll() }
            } label: {
                // Label shows the known-parsed count; an edited-but-unparsed line can
                // still enable Save (confirm re-parses), so fall back to a plain "Save".
                Text(model.isSaving ? "Saving…" : saveLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canConfirm || model.isSaving)

            Button("Start over", action: model.reset)
                .font(.footnote)
                .disabled(model.isSaving)   // can't clear candidates mid-save
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var saveLabel: String {
        guard model.canConfirm else { return "Nothing to save" }
        let n = model.confirmableCount
        return n > 0 ? "Save \(n) line\(n == 1 ? "" : "s")" : "Save"
    }

    // MARK: - Terminal states

    private var emptyState: some View {
        outcomeCard(icon: "doc.questionmark",
                    title: "Couldn't read that image",
                    message: "Try a clearer, well-lit photo, or type your sets manually.",
                    color: Theme.gold) {
            Button("Try another", action: model.reset).buttonStyle(.bordered)
        }
    }

    private func savedState(_ count: Int) -> some View {
        outcomeCard(icon: "checkmark.circle.fill",
                    title: "Saved \(count) set\(count == 1 ? "" : "s")",
                    message: "Added to your current workout.",
                    color: Theme.kelp) {
            HStack(spacing: 12) {
                Button("Scan another", action: model.reset).buttonStyle(.bordered)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func failedState(_ message: String) -> some View {
        // A save failure keeps the reviewed lines (return to review); an image-load
        // failure has none (start over).
        let hasCandidates = !model.candidates.isEmpty
        return outcomeCard(icon: "exclamationmark.triangle.fill",
                    title: message,
                    message: hasCandidates
                        ? "Nothing was saved. Your reviewed lines are kept — adjust and try again."
                        : "Nothing was saved. Pick another photo to try again.",
                    color: .red) {
            if hasCandidates {
                Button("Back to review", action: model.backToReview)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Choose another photo", action: model.reset)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func outcomeCard<Actions: View>(icon: String, title: String, message: String,
                                            color: Color, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(color)
            Text(title).font(.headline).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(Theme.steel).multilineTextAlignment(.center)
            actions()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "135 lb × 8 · 2 sets" style summary of a candidate's parsed sets.
    static func summary(for sets: [SetDraft]) -> String {
        guard let first = sets.first else { return "" }
        let name = first.exerciseName.isEmpty ? "(needs a name)" : first.exerciseName
        let spec = TodayView.summary(for: first)
        let more = sets.count > 1 ? " · \(sets.count) sets" : ""
        return "\(name) — \(spec)\(more)"
    }
}

/// One reviewable OCR line. Owns its editing text as local `@State` (seeded from the
/// candidate) so the model's `candidates` stays `private(set)`; edits commit back via
/// `onCommit`, which re-parses. Read-only inputs otherwise.
private struct OCRCandidateRow: View {
    let candidate: OCRLineCandidate
    /// Whether this row will be persisted on confirm (model.willSave) — drives the
    /// checkbox so the visible state matches exactly what saves, including an
    /// edited-but-uncommitted line that will be re-parsed at confirm.
    let willSave: Bool
    let lowConfidence: Bool
    let onTextChange: (String) -> Void
    let onCommit: () async -> Void
    let onToggleInclude: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(candidate: OCRLineCandidate, willSave: Bool, lowConfidence: Bool,
         onTextChange: @escaping (String) -> Void,
         onCommit: @escaping () async -> Void, onToggleInclude: @escaping () -> Void) {
        self.candidate = candidate
        self.willSave = willSave
        self.lowConfidence = lowConfidence
        self.onTextChange = onTextChange
        self.onCommit = onCommit
        self.onToggleInclude = onToggleInclude
        _text = State(initialValue: candidate.text)
    }

    /// The toggle is actionable when the row would save (so you can uncheck it) or has
    /// been explicitly skipped (so you can re-check it). Only an untouched, still-
    /// unreadable scan is non-toggleable — there's nothing to include yet.
    private var toggleEnabled: Bool { willSave || candidate.userExcluded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: onToggleInclude) {
                    Image(systemName: willSave ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(willSave ? Theme.kelp : Theme.steel)
                }
                .buttonStyle(.plain)
                .disabled(!toggleEnabled)
                .accessibilityLabel(willSave ? "Included" : "Skipped")

                TextField("Line text", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    // Keep the model's `text` live on every keystroke (cheap, no parse),
                    // so confirmAll's re-parse always sees the latest text.
                    .onChange(of: text) { _, newValue in onTextChange(newValue) }
                    // Re-parse on return *and* on losing focus, so a correction is
                    // reflected even without pressing return.
                    .onChange(of: focused) { wasFocused, isFocused in
                        if wasFocused && !isFocused { Task { await onCommit() } }
                    }
                    .onSubmit { Task { await onCommit() } }
            }

            if candidate.isParsed {
                Text(OCRCaptureView.summary(for: candidate.sets))
                    .font(.caption)
                    .foregroundStyle(Theme.steel)
            } else {
                Label("Couldn't read this as a set — edit it (then return), or leave it unchecked to skip.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.gold)
            }

            if lowConfidence {
                Label("Low confidence — double-check this one.", systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(Theme.gold)
            }
        }
        .padding(.vertical, 4)
    }
}
