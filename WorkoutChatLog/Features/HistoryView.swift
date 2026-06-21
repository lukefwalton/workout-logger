import SwiftUI

/// The trust-restoring view: every saved set, grouped by workout, with delete and
/// edit (set & session). Thin presentation over `HistoryModel`; all writes go
/// through dedicated store APIs.
///
/// NOTE: written correct-by-inspection — not run in a simulator in this
/// environment; first real verification is an Xcode/device launch.
struct HistoryView: View {
    @StateObject private var model: HistoryModel
    @State private var editingSet: EditingSet?
    @State private var editingSession: HistoryModel.Section?

    init(store: WorkoutStore) {
        _model = StateObject(wrappedValue: HistoryModel(store: store))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("History")
                .task { await model.load() }
                .refreshable { await model.load() }
                .sheet(item: $editingSet) { editing in
                    SetEditorView(row: editing.row) { name, weight, unit, kind, reps, rir, type, notes in
                        model.updateSet(editing.row.setID, exerciseName: name, weight: weight, unit: unit,
                                        loadKind: kind, reps: reps, rir: rir, setType: type, notes: notes)
                    }
                }
                .sheet(item: $editingSession) { section in
                    SessionEditorView(section: section) { name, start, end, notes, feel, deload in
                        model.updateSession(section.id, name: name, startedAt: start, endedAt: end,
                                            notes: notes, feel: feel, isDeload: deload)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ContentUnavailableView { Label("Loading…", systemImage: "clock") }
        case .empty:
            HistoryHeroEmpty()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load history", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .loaded(let sections):
            list(sections)
        }
    }

    /// First-run empty state. Borrows the political onboarding HeroIcon's
    /// circle + gold border + soft shadow so the History tab has a moment of
    /// quiet design before any data arrives, rather than a system stub.
    private struct HistoryHeroEmpty: View {
        var body: some View {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .fill(Theme.ocean.opacity(0.10))
                    Circle()
                        .strokeBorder(Theme.gold.opacity(0.55), lineWidth: 1.5)
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 42, weight: .regular))
                        .foregroundStyle(Theme.ocean)
                }
                .frame(width: 112, height: 112)
                .shadow(color: Theme.deepSea.opacity(0.18), radius: 16, y: 10)

                VStack(spacing: 8) {
                    Text("NO WORKOUTS YET")
                        .font(.caption.weight(.heavy))
                        .kerning(2)
                        .foregroundStyle(Theme.gold)
                    Text("Every set you log\nlands here.")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    Text("Log a set on Today and it'll show up here, grouped by workout, ready to edit or share.")
                        .font(.footnote)
                        .foregroundStyle(Theme.steel)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 28)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper.ignoresSafeArea())
        }
    }

    private func list(_ sections: [HistoryModel.Section]) -> some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows, id: \.setID) { row in
                        setRow(row)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { model.deleteSet(row.setID) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { editingSet = EditingSet(row: row) } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(Theme.ocean)
                            }
                    }
                } header: {
                    sectionHeader(section)
                } footer: {
                    if let notes = section.notes, !notes.isEmpty {
                        Text(notes).font(.footnote)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func sectionHeader(_ section: HistoryModel.Section) -> some View {
        HStack(spacing: 8) {
            if let feel = section.feel {
                Image(systemName: feel.symbol).foregroundStyle(Theme.ocean)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.headline).textCase(nil)
                Text(subtitle(section)).font(.caption)
                if let calorie = Self.calorieLabel(section.calorie) {
                    Text(calorie).font(.caption2).foregroundStyle(Theme.steel).textCase(nil)
                }
            }
            Spacer()
            Menu {
                Button { editingSession = section } label: { Label("Edit workout", systemImage: "pencil") }
                Button(role: .destructive) { model.deleteSession(section.id) } label: {
                    Label("Delete workout", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("Workout options")
        }
    }

    private func subtitle(_ section: HistoryModel.Section) -> String {
        var parts = ["\(section.setCount) set\(section.setCount == 1 ? "" : "s")"]
        if section.isDeload { parts.append("deload") }
        if let feel = section.feel { parts.append(feel.label) }
        return parts.joined(separator: " · ")
    }

    /// Honest, rough calorie line for the session header — "~X kcal (estimate)" when
    /// we can estimate, a gentle prompt when bodyweight is missing, and nothing when
    /// there's no usable duration (rather than nag).
    static func calorieLabel(_ outcome: CalorieEstimate.Outcome) -> String? {
        switch outcome {
        case .kcal(let value, _): return "~\(value) kcal (estimate)"
        case .needsBodyweight: return "Add your bodyweight in Settings to estimate calories"
        case .needsDuration: return nil
        }
    }

    private func setRow(_ row: WorkoutSetHistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.exerciseName).fontWeight(.semibold)
            Text(Self.summary(for: row)).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// "135 lb × 8 · warmup · 2 RIR" — only the parts present.
    static func summary(for row: WorkoutSetHistoryRow) -> String {
        var parts = ["\(row.load.displayText) × \(row.reps)"]
        if row.setType != .working { parts.append(row.setType.rawValue) }
        if let rir = row.rir { parts.append("\(rir) RIR") }
        return parts.joined(separator: " · ")
    }

    private struct EditingSet: Identifiable {
        var id: Int64 { row.setID }
        let row: WorkoutSetHistoryRow
    }
}

/// Edit one logged set. Mirrors the save-path fields; the store re-validates and
/// re-resolves the exercise name, so a rejected edit surfaces a message and the
/// sheet stays open.
private struct SetEditorView: View {
    let row: WorkoutSetHistoryRow
    let onSave: (String, Double, WeightUnit, WorkoutLoadKind, Int, Int?, SetType, String?) -> String?
    @Environment(\.dismiss) private var dismiss

    @State private var exerciseName: String
    @State private var weight: Double
    @State private var unit: WeightUnit
    @State private var loadKind: WorkoutLoadKind
    @State private var reps: Int
    @State private var rir: Int?
    @State private var setType: SetType
    @State private var notes: String
    @State private var error: String?

    init(row: WorkoutSetHistoryRow,
         onSave: @escaping (String, Double, WeightUnit, WorkoutLoadKind, Int, Int?, SetType, String?) -> String?) {
        self.row = row
        self.onSave = onSave
        _exerciseName = State(initialValue: row.exerciseName)
        _weight = State(initialValue: row.load.amount ?? 0)
        _unit = State(initialValue: row.load.unit ?? .lb)
        _loadKind = State(initialValue: row.load.kind)
        _reps = State(initialValue: row.reps)
        _rir = State(initialValue: row.rir)
        _setType = State(initialValue: row.setType)
        _notes = State(initialValue: row.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Exercise", text: $exerciseName)
                        .textInputAutocapitalization(.words)
                }
                Section("Load") {
                    Picker("Type", selection: $loadKind) {
                        ForEach(WorkoutLoadKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    // Weight is meaningless for bodyweight/unspecified — the load
                    // kind carries the intent, so don't surface (or write) a "0 lb".
                    if loadKind != .bodyweight && loadKind != .unspecified {
                        HStack {
                            Text("Weight")
                            Spacer()
                            TextField("0", value: $weight, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                            Picker("Unit", selection: $unit) {
                                ForEach(WeightUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }
                }
                Section("Set") {
                    Stepper("Reps: \(reps)", value: $reps, in: 1...100)
                    Picker("RIR", selection: $rir) {
                        Text("Not set").tag(Int?.none)
                        ForEach(0...10, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                    Picker("Set type", selection: $setType) {
                        ForEach(SetType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical).lineLimit(1...4)
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Edit set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
    }

    private func save() {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bodyweight/unspecified carry no amount; store 0 so a stale weight from a
        // prior load kind can't linger behind the (hidden) field.
        let effectiveWeight = (loadKind == .bodyweight || loadKind == .unspecified) ? 0 : weight
        if let message = onSave(exerciseName, effectiveWeight, unit, loadKind, reps, rir, setType,
                                trimmed.isEmpty ? nil : trimmed) {
            error = message
        } else {
            dismiss()
        }
    }
}

/// Edit / post-fill a session's name, times, feel, deload, and notes. The store
/// rejects an end earlier than the start.
private struct SessionEditorView: View {
    let section: HistoryModel.Section
    let onSave: (String?, Date?, Date?, String?, SessionFeel?, Bool) -> String?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var isFinished: Bool
    @State private var feel: SessionFeel?
    @State private var isDeload: Bool
    @State private var notes: String
    @State private var error: String?

    init(section: HistoryModel.Section,
         onSave: @escaping (String?, Date?, Date?, String?, SessionFeel?, Bool) -> String?) {
        self.section = section
        self.onSave = onSave
        let start = WorkoutStore.date(section.startedAt) ?? Date()
        _name = State(initialValue: section.name ?? "")
        _startedAt = State(initialValue: start)
        _endedAt = State(initialValue: WorkoutStore.date(section.endedAt) ?? start)
        _isFinished = State(initialValue: section.endedAt != nil)
        _feel = State(initialValue: section.feel)
        _isDeload = State(initialValue: section.isDeload)
        _notes = State(initialValue: section.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Workout name", text: $name)
                }
                Section("Times") {
                    DatePicker("Started", selection: $startedAt)
                    // Only an in-progress workout offers "Finished" (leave open vs.
                    // close). An already-finished one stays finished — reopening
                    // isn't supported (and the single-open index would forbid two
                    // open sessions); you can still edit its end time below.
                    if section.endedAt == nil {
                        Toggle("Finished", isOn: $isFinished)
                    }
                    if isFinished {
                        DatePicker("Ended", selection: $endedAt)
                    }
                }
                Section("How it felt") {
                    Picker("Feel", selection: $feel) {
                        Text("Not set").tag(SessionFeel?.none)
                        ForEach(SessionFeel.allCases, id: \.self) { Text($0.label).tag(SessionFeel?.some($0)) }
                    }
                    Toggle("Deload session", isOn: $isDeload)
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical).lineLimit(1...4)
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = onSave(trimmedName.isEmpty ? nil : trimmedName,
                                startedAt,
                                isFinished ? endedAt : nil,
                                trimmedNotes.isEmpty ? nil : trimmedNotes,
                                feel, isDeload) {
            error = message
        } else {
            dismiss()
        }
    }
}
