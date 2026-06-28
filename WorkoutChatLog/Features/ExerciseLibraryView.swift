import SwiftUI

/// Settings → Exercises: the surface for fixing the duplicates that
/// unknown-exercise creation inevitably produces ("Lat Pulldown" vs "Lat Pull
/// Down"), because duplicate canonicals fragment progress charts. Rename, merge
/// duplicates, and delete unused customs — all through dedicated store APIs.
///
/// NOTE: correct-by-inspection; the list/merge UX wants an Xcode/device pass.
struct ExerciseLibraryView: View {
    let store: WorkoutStore

    @State private var exercises: [ManagedExercise] = []
    @State private var loadError: String?
    @State private var search = ""
    @State private var renaming: ManagedExercise?
    @State private var renameText = ""
    @State private var merging: ManagedExercise?
    @State private var actionError: String?

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(families, id: \.key) { family in
                Section(familyTitle(family.key)) {
                    ForEach(family.items) { exercise in row(exercise) }
                }
            }
        }
        .navigationTitle("Exercises")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search)
        .task { load() }
        .refreshable { load() }
        .alert("Rename exercise", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText).textInputAutocapitalization(.words)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Renames the display name everywhere. History is unaffected — the exercise keeps its identity.")
        }
        .sheet(item: $merging) { source in
            MergeTargetPicker(source: source, candidates: exercises.filter { $0.id != source.id }) { target in
                performMerge(source: source, into: target)
            }
        }
        .alert("Couldn't update", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @MainActor
    private func row(_ exercise: ManagedExercise) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.canonicalName)
                Text("\(exercise.usageCount) set\(exercise.usageCount == 1 ? "" : "s")" + (exercise.isCustom ? " · custom" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button { startRename(exercise) } label: { Label("Rename", systemImage: "pencil") }
                Button { merging = exercise } label: { Label("Merge into…", systemImage: "arrow.triangle.merge") }
                if exercise.isCustom && exercise.usageCount == 0 {
                    Button(role: .destructive) { performDelete(exercise) } label: { Label("Delete", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .accessibilityLabel("\(exercise.canonicalName) options")
        }
    }

    // MARK: - Grouping

    private var filtered: [ManagedExercise] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return exercises }
        return exercises.filter { $0.canonicalName.lowercased().contains(query) }
    }

    private var families: [(key: String, items: [ManagedExercise])] {
        Dictionary(grouping: filtered) { $0.familyKey ?? "" }
            .map { (key: $0.key, items: $0.value) }
            .sorted { lhs, rhs in
                if lhs.key.isEmpty != rhs.key.isEmpty { return !lhs.key.isEmpty }   // singletons ("Other") last
                return lhs.key < rhs.key
            }
    }

    private func familyTitle(_ key: String) -> String {
        key.isEmpty ? "Other" : key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    // MARK: - Actions

    @MainActor
    private func load() {
        do { exercises = try store.managedExercises(); loadError = nil }
        catch { loadError = "Couldn't load exercises." }
    }

    private func startRename(_ exercise: ManagedExercise) {
        renameText = exercise.canonicalName
        renaming = exercise
    }

    @MainActor
    private func performRename() {
        guard let exercise = renaming else { return }
        do {
            try store.renameExercise(exercise.id, to: renameText)
            renaming = nil
            load()
        } catch {
            renaming = nil
            actionError = message(for: error)
        }
    }

    @MainActor
    private func performMerge(source: ManagedExercise, into target: ManagedExercise) {
        do {
            try store.mergeExercise(from: source.id, into: target.id)
            merging = nil
            load()
        } catch {
            merging = nil
            actionError = message(for: error)
        }
    }

    @MainActor
    private func performDelete(_ exercise: ManagedExercise) {
        do { try store.deleteExercise(exercise.id); load() }
        catch { actionError = message(for: error) }
    }

    private func message(for error: Error) -> String {
        (error as? WorkoutStoreError)?.description ?? "Something went wrong. Try again."
    }
}

/// Pick the exercise to merge a duplicate into. The copy is explicit that merge
/// is for duplicates, not variations; same-family is surfaced as a weak hint, not
/// a gate (the app can't know intent).
private struct MergeTargetPicker: View {
    let source: ManagedExercise
    let candidates: [ManagedExercise]
    let onPick: (ManagedExercise) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var confirming: ManagedExercise?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Moves all of \"\(source.canonicalName)\"'s sets into the one you pick and deletes it. Use it only for duplicates of the same exercise — not different variations (a Close-Grip Push-Up is not a Push-Up).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(filtered) { candidate in
                    Button { confirming = candidate } label: {
                        HStack {
                            Text(candidate.canonicalName).foregroundStyle(.primary)
                            if let family = source.familyKey, candidate.familyKey == family {
                                Spacer()
                                Text("same family").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Merge into…")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .confirmationDialog("Merge “\(source.canonicalName)” into “\(confirming?.canonicalName ?? "")”?",
                                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible) {
                Button("Merge and delete \(source.canonicalName)", role: .destructive) {
                    if let target = confirming { onPick(target) }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            } message: {
                Text("This permanently moves all sets and can't be undone.")
            }
        }
    }

    private var filtered: [ManagedExercise] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.canonicalName.lowercased().contains(query) }
    }
}
