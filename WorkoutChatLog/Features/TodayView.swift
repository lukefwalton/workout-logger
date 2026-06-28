import SwiftUI
import UIKit

/// The first real flow: type a set, parse it, confirm, save. Logic lives in
/// `TodayModel`; this view is thin presentation over that state.
///
/// NOTE: written correctly-by-inspection but not run in a simulator in this
/// environment — first real verification is an Xcode/device launch.
struct TodayView: View {
    @StateObject private var model: TodayModel
    @StateObject private var restTimer = RestTimerModel()
    @AppStorage(RestTimerPreferences.defaultDurationKey) private var restTimerDefaultSeconds = 0.0
    /// Source of truth for the parser's default weight unit. The model listens to
    /// this via `setDefaultUnit` so a Settings flip starts parsing new entries in
    /// the new unit immediately — without rewriting any stored set.
    @AppStorage(UnitPreferences.defaultUnitKey) private var defaultUnitRaw = WeightUnit.lb.rawValue
    private let store: WorkoutStore
    @FocusState private var inputFocused: Bool
    @State private var showingFinish = false
    @State private var finishFeel: SessionFeel?
    @State private var finishDeload = false
    @State private var finishNotes = ""
    @State private var finishError: String?
    @State private var plateSheet: PlateSheetInput?
    @State private var showingScan = false
    @State private var scrollRequest: TodayScrollAnchor?

    init(store: WorkoutStore) {
        self.store = store
        _model = StateObject(wrappedValue: TodayModel(store: store))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        hero

                        // Each .animation(value:) below is scoped to a Group that
                        // wraps *only* its conditional view, so unrelated layout
                        // changes elsewhere in the VStack (modeControl picker
                        // reflows, SupplementsCardView text updates, etc.) can't
                        // ride the same spring when these state values flip.
                        // Same response/damping as the political onboarding's
                        // PageDots so the system feels of-a-piece.
                        Group {
                            if model.hasActiveWorkout {
                                activeWorkoutBanner
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.42, dampingFraction: 0.82),
                                   value: model.hasActiveWorkout)

                        modeControl

                        switch model.mode {
                        case .freeForm:
                            freeFormCard
                        case .workoutPlan:
                            workoutPlanCard
                        }

                        Group {
                            if let pending = model.pending {
                                confirmCard(for: pending)
                                    .id(TodayScrollAnchor.confirm)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.42, dampingFraction: 0.82),
                                   value: model.pending?.startedAt)

                        // A running/finished countdown persists across status changes (a
                        // new parse mustn't hide an active rest), so it lives here rather
                        // than only inside the post-save status. The "start rest" prompt
                        // stays in the saved-status branch where it's contextual.
                        Group {
                            if restTimer.phase != .idle {
                                restTimerControl
                                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.36, dampingFraction: 0.80),
                                   value: restTimer.phase)

                        statusSection
                            .id(TodayScrollAnchor.status)

                        SupplementsCardView(store: store)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 120)
                }
                .background(Theme.paper.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: scrollRequest) { _, target in
                    guard let target else { return }
                    Task { @MainActor in
                        // One layout pass so the confirm card exists before scroll.
                        await Task.yield()
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(target, anchor: target == .confirm ? .center : .top)
                        }
                        scrollRequest = nil
                    }
                }
                .onAppear {
                    model.reconcileActiveSession()
                    model.setDefaultUnit(UnitPreferences.resolved(defaultUnitRaw))
                }
                .onChange(of: defaultUnitRaw) { _, new in
                    model.setDefaultUnit(UnitPreferences.resolved(new))
                }
                .sheet(isPresented: $showingFinish) { finishSheet }
                .sheet(isPresented: $showingScan, onDismiss: { model.reconcileActiveSession() }) {
                    OCRCaptureView(store: store)
                }
                .sheet(item: $plateSheet) { input in
                    PlateCalculatorSheet(target: input.target, unit: input.unit)
                }
            }
        }
    }

    private var activeWorkoutBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.title3)
                .foregroundStyle(Theme.ocean)
            VStack(alignment: .leading, spacing: 2) {
                Text("Current workout")
                    .font(.subheadline).fontWeight(.bold).foregroundStyle(Theme.ink)
                Text("\(model.activeSessionSetCount) set\(model.activeSessionSetCount == 1 ? "" : "s") logged")
                    .font(.caption).foregroundStyle(Theme.steel)
            }
            Spacer()
            Button("Finish workout", action: presentFinish)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ocean.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func presentFinish() {
        finishFeel = nil
        finishDeload = false
        finishNotes = ""
        finishError = nil
        showingFinish = true
    }

    private var finishSheet: some View {
        NavigationStack {
            Form {
                Section("How did it feel?") {
                    HStack(spacing: 10) {
                        ForEach(SessionFeel.allCases, id: \.self) { feel in
                            Button {
                                finishFeel = (finishFeel == feel) ? nil : feel
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: feel.symbol).font(.title2)
                                    Text(feel.label).font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(finishFeel == feel ? Theme.ocean.opacity(0.15) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .foregroundStyle(finishFeel == feel ? Theme.ocean : Theme.steel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Toggle("Deload session", isOn: $finishDeload)
                } footer: {
                    Text("Deload and off-day sessions can be excluded from progress trends.")
                }
                Section("Notes") {
                    TextField("Optional", text: $finishNotes, axis: .vertical)
                        .lineLimit(2...5)
                }
                if let finishError {
                    Text(finishError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Finish workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingFinish = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") {
                        // Keep the sheet (and entered metadata) on failure; dismiss
                        // only once the workout actually closed.
                        if let message = model.finishWorkout(feel: finishFeel, isDeload: finishDeload, notes: finishNotes) {
                            finishError = message
                        } else {
                            showingFinish = false
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.system(size: 42, weight: .black, design: .rounded))
                // Cap Dynamic Type so the 42-pt hero doesn't blow the layout at
                // accessibility sizes; the body copy below scales normally.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)

            Text(model.mode == .freeForm
                 ? "Drop in a shorthand set. The app parses it, you confirm it, then it writes locally."
                 : "Pick today's plan, then log each exercise with set specs only.")
                .font(.subheadline)
                .foregroundStyle(Theme.steel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeControl: some View {
        InputModeToggle(selection: Binding(get: { model.mode }, set: model.setMode))
    }

    private var freeFormCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Log a set", systemImage: "bolt.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button {
                        showingScan = true
                    } label: {
                        Label("Scan", systemImage: "doc.text.viewfinder")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ocean)
                    }
                    .accessibilityLabel("Scan a workout sheet")
                }

                HStack(spacing: 12) {
                    TextField("bench 135x8", text: $model.inputText)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.ink)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($inputFocused)
                        .onSubmit(parseInput)
                        .accessibilityHint("Type a set in shorthand, then tap Parse.")

                    parseSubmitButton(enabled: canParse, action: parseInput)
                }
                .padding(14)
                .background(Theme.paper.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                inputAutocompleteChips

                VStack(alignment: .leading, spacing: 10) {
                    Text("Try one")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.steel)
                        .textCase(.uppercase)

                    FlowLayout(spacing: 8) {
                        ForEach(examples, id: \.self) { example in
                            Button {
                                model.inputText = example
                                inputFocused = true
                            } label: {
                                Text(example)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .background(Theme.ocean.opacity(0.10), in: Capsule())
                                    .foregroundStyle(Theme.ocean)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var workoutPlanCard: some View {
        VStack(spacing: 16) {
            planSetupCard
            if !model.plannedExercises.isEmpty {
                activePlanCard
            }
        }
    }

    private var planSetupCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                Label("Workout Plan", systemImage: "list.bullet.clipboard.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)

                if model.savedPlans.isEmpty {
                    Text("Paste a plain text list of exercises, one per line.")
                        .font(.footnote)
                        .foregroundStyle(Theme.steel)
                } else {
                    Menu {
                        ForEach(model.savedPlans) { plan in
                            Button(plan.name) {
                                model.selectSavedPlan(plan.id)
                                inputFocused = true
                            }
                        }
                    } label: {
                        Label(selectedSavedPlanTitle, systemImage: "chevron.down.circle")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }

                TextField("Plan name, e.g. Leg Day", text: $model.planName)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Theme.paper.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                TextEditor(text: $model.planText)
                    .font(.system(.body, design: .rounded))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Theme.paper.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if model.planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Bench Press\nIncline DB Press\nCable Row\nLateral Raise")
                                .foregroundStyle(Theme.steel.opacity(0.55))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: 12) {
                    Button("Save plan", action: model.saveCurrentPlan)
                        .buttonStyle(.bordered)
                        .disabled(!model.canStartPlan)
                    Button("Start plan", action: model.startPlan)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartPlan)
                }
            }
        }
    }

    private var activePlanCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Today's checklist", systemImage: "checklist")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Clear", role: .destructive, action: model.clearActivePlan)
                        .font(.caption)
                        .buttonStyle(.bordered)
                }

                VStack(spacing: 8) {
                    ForEach(model.plannedExercises) { exercise in
                        Button {
                            model.selectPlannedExercise(exercise.id)
                            inputFocused = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: exercise.id == model.selectedPlannedExerciseID ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(exercise.id == model.selectedPlannedExerciseID ? Theme.ocean : Theme.steel)
                                Text(exercise.name)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                if exercise.loggedSetCount > 0 {
                                    Text("\(exercise.loggedSetCount) set\(exercise.loggedSetCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundStyle(Theme.kelp)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Theme.kelp.opacity(0.12), in: Capsule())
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(exercise.id == model.selectedPlannedExerciseID ? Theme.ocean.opacity(0.10) : Theme.paper.opacity(0.85),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 12) {
                    TextField(planInputPlaceholder, text: $model.inputText)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.ink)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($inputFocused)
                        .onSubmit(parseInput)

                    parseSubmitButton(enabled: canParseInPlan, action: parseInput)
                }
                .padding(14)
                .background(Theme.paper.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func parseSubmitButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if model.isParsing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.forward")
                        .font(.system(size: 17, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background((enabled && !model.isParsing) ? Theme.ocean.gradient : Theme.steel.opacity(0.25).gradient,
                        in: Circle())
        }
        .disabled(!enabled || model.isParsing)
        .accessibilityLabel(model.isParsing ? "Parsing set" : "Parse set")
    }

    private func confirmCard(for pending: WorkoutDraft) -> some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                Label("Confirm before saving", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)

                if model.pendingParseSource == .appleIntelligence {
                    Label("Parsed with Apple Intelligence — check it before saving.",
                          systemImage: "sparkles")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ocean)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Theme.ocean.opacity(0.10), in: Capsule())
                }

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Exercise")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(Theme.steel)
                        TextField("Exercise", text: Binding(
                            get: { model.pendingExerciseName },
                            set: model.setExerciseName))
                            .font(.headline)
                            .textFieldStyle(.plain)
                            .textInputAutocapitalization(.words)
                    }
                    .fieldPill()

                    if !model.pendingSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Did you mean…")
                                .font(.caption).fontWeight(.bold)
                                .foregroundStyle(Theme.steel).textCase(.uppercase)
                            FlowLayout(spacing: 8) {
                                ForEach(model.pendingSuggestions) { suggestion in
                                    Button { model.applySuggestion(suggestion) } label: {
                                        Text(suggestion.canonicalName)
                                            .font(.caption).fontWeight(.semibold)
                                            .padding(.horizontal, 11).padding(.vertical, 8)
                                            .background(Theme.kelp.opacity(0.12), in: Capsule())
                                            .foregroundStyle(Theme.kelp)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.kelp.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if model.pendingCreatesNewExercise {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Theme.gold)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("New exercise")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundStyle(Theme.ink)
                                Text("Saving will add \(model.pendingExerciseName) to your local exercise library.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.steel)
                            }
                        }
                        .padding(12)
                        .background(Theme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if let lastTime = model.lastTime {
                        lastTimeRow(lastTime)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Weight")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(Theme.steel)
                        HStack(spacing: 8) {
                            TextField("0", value: Binding(get: { model.pendingWeight },
                                                          set: model.setWeight),
                                      format: .number)
                                .font(.headline)
                                .textFieldStyle(.plain)
                                .keyboardType(.decimalPad)
                                .accessibilityLabel("Weight in \(model.pendingUnit.rawValue)")
                            // The unit toggle is the safety valve for the High-severity
                            // finding: a kg user typing "100x5" can flip to kg here
                            // before saving instead of having 100 lb silently persisted.
                            // Tap buttons instead of a segmented picker — horizontal
                            // swipes on segmented controls fight the tab pager.
                            WeightUnitToggle(selection: Binding(get: { model.pendingUnit },
                                                                set: model.setUnit))
                                .accessibilityLabel("Weight unit")
                        }
                    }
                    .fieldPill()

                    // Shared reps editor — shown only when every set carries the
                    // same rep count (or none do yet), so a parsed uneven entry
                    // like 8,8,7 isn't flattened by one field. Uneven drafts keep
                    // their per-set summary below as the source of truth.
                    if model.pendingRepsAreUniform {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Reps")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(Theme.steel)
                            TextField("Add reps", value: Binding(get: { model.pendingReps },
                                                                 set: model.setReps),
                                      format: .number)
                                .font(.headline)
                                .textFieldStyle(.plain)
                                .keyboardType(.numberPad)
                                .accessibilityLabel("Reps per set")
                        }
                        .fieldPill()
                    }

                    // Plate calculator (§4): barbell loads only. Gated to `.external`
                    // so it never appears for bodyweight-plus / assisted entries, where
                    // a "load the bar" sheet would be misleading.
                    if model.pendingWeight > 0,
                       let firstSet = pending.sets.first,
                       firstSet.loadKind == .external {
                        let unit = firstSet.unit
                        Button {
                            plateSheet = PlateSheetInput(target: model.pendingWeight, unit: unit)
                        } label: {
                            Label("Plate calculator", systemImage: "circle.hexagongrid.fill")
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(Theme.ocean)
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(spacing: 8) {
                    HStack {
                        Text("Sets")
                            .font(.caption).fontWeight(.bold)
                            .foregroundStyle(Theme.steel).textCase(.uppercase)
                        Spacer()
                        Button { model.removeSet() } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(model.pendingSetCount > 1 ? Theme.ocean : Theme.steel.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.pendingSetCount <= 1)
                        .accessibilityLabel("Remove a set")
                        Text("\(model.pendingSetCount)")
                            .font(.headline).monospacedDigit()
                            .frame(minWidth: 28)
                            .foregroundStyle(Theme.ink)
                        Button { model.addSet() } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.ocean)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add a set")
                    }

                    // Sets⇄reps swap: the parser makes its best guess for an
                    // ambiguous scheme ("5x3" → 5 sets × 3 reps); one tap flips
                    // which number is which. Shown only when the flip stays
                    // savable (`pendingCanSwapSetsReps`).
                    if model.pendingCanSwapSetsReps {
                        Button(action: model.swapSetsAndReps) {
                            Label("Swap to \(model.pendingReps ?? 0) sets × \(model.pendingSetCount) reps",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(Theme.ocean)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHint("Reinterpret which number is sets and which is reps")
                    }

                    ForEach(Array(pending.sets.enumerated()), id: \.offset) { index, set in
                        HStack {
                            Text("Set \(index + 1)")
                                .fontWeight(.bold)
                                .foregroundStyle(Theme.steel)
                            Spacer()
                            Text(Self.summary(for: set))
                                .foregroundStyle(Theme.ink)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.paper.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }

                HStack(spacing: 12) {
                    Button("Discard", role: .destructive, action: model.discard)
                        .buttonStyle(.bordered)
                    Button("Save workout", action: saveWorkout)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSave)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: Theme.deepSea.opacity(0.10), radius: 24, y: 14)
    }

    /// Parsing is async (the FM layer awaits the on-device model), so the button /
    /// keyboard-submit actions hop onto a Task. The model serializes the state it
    /// publishes on the main actor. After a result lands, scroll to the confirm
    /// card or the status message so the user sees that something happened.
    private func parseInput() {
        dismissKeyboard()
        Task {
            await model.parse()
            scrollRequest = scrollTargetAfterParse()
        }
    }

    private func dismissKeyboard() {
        inputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func scrollTargetAfterParse() -> TodayScrollAnchor? {
        if model.pending != nil { return .confirm }
        switch model.status {
        case .declined, .needsClarification, .failed:
            return .status
        case .idle, .saved:
            return nil
        }
    }

    private func saveWorkout() {
        dismissKeyboard()
        model.save()
        if case .saved = model.status {
            scrollRequest = .status
        } else if case .failed = model.status {
            scrollRequest = .status
        }
    }

    private var canParse: Bool {
        !model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canParseInPlan: Bool {
        canParse && model.selectedPlannedExercise != nil
    }

    private var selectedSavedPlanTitle: String {
        guard let selected = model.selectedSavedPlanID,
              let plan = model.savedPlans.first(where: { $0.id == selected }) else {
            return "Select saved plan"
        }
        return plan.name
    }

    private var planInputPlaceholder: String {
        model.selectedPlannedExercise == nil ? "Select an exercise" : "135x8"
    }

    private var examples: [String] {
        ["135x8", "3x10 @ 135", "135 for 8,8,7", "bw x12", "225x5 rpe 8"]
    }

    /// Compact "did you mean this lift?" chips under the input while the user is
    /// typing — the canonical/alias/fuzzy stack is the same one the confirm card
    /// already uses; this surfaces it earlier so a typo never has to wait until
    /// after a save attempt. Hidden when `model.inputSuggestions` is empty
    /// (which it is below the two-letter floor or on an exact-name match).
    @ViewBuilder
    private var inputAutocompleteChips: some View {
        if !model.inputSuggestions.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(model.inputSuggestions) { suggestion in
                    Button {
                        model.applyInputSuggestion(suggestion)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                                .font(.caption2)
                                .accessibilityHidden(true)
                            Text(suggestion.canonicalName)
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(Theme.kelp.opacity(0.12), in: Capsule())
                        .foregroundStyle(Theme.kelp)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(suggestion.canonicalName)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Suggested exercises")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.status {
        case .declined:
            // Specific diagnosis (rep ranges, cardio, supersets, …) when the
            // parser had one — falls back to the generic "try a shape like…"
            // copy when it didn't. Real reasons beat a stock prompt every time.
            statusCard(icon: "questionmark.circle.fill",
                       title: Self.declineTitle(model.lastDeclineReason),
                       message: Self.declineMessage(model.lastDeclineReason),
                       color: Theme.gold)
        case .needsClarification(let prompt):
            clarificationCard(prompt)
        case .saved(let count):
            VStack(alignment: .leading, spacing: 10) {
                statusCard(icon: "checkmark.circle.fill",
                           title: "Saved \(count) set\(count == 1 ? "" : "s")",
                           message: "Logged locally on this phone.",
                           color: Theme.kelp)
                    .transition(.move(edge: .top).combined(with: .opacity))
                // Inline Undo: deletes the sets the visible "saved N sets" notice
                // refers to. Cleared by the next parse / discard / save, so it
                // only ever undoes the *just-shown* save (not yesterday's).
                if model.lastSaveUndoToken != nil {
                    Button(action: model.undoLastSave) {
                        Label("Undo last save", systemImage: "arrow.uturn.backward")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(Theme.ocean)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Removes the \(count) just-saved set\(count == 1 ? "" : "s") from your history.")
                }
                // PR moments (§4): one tasteful card per detected personal record,
                // computed from logged sets — SF Symbol, never emoji. The gold
                // glow + scale-in spring is the one moment in the app worth
                // celebrating, modeled after the political onboarding hero icon.
                ForEach(model.lastAchievements) { achievement in
                    achievementCard(achievement)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                // The contextual "start rest" prompt after a save. The running/finished
                // countdown renders separately (above statusSection) so it persists.
                if restTimer.phase == .idle { restStartButton }
            }
            .animation(.spring(response: 0.48, dampingFraction: 0.72),
                       value: model.lastAchievements.map(\.id))
        case .failed(let message):
            statusCard(icon: "exclamationmark.triangle.fill",
                       title: message,
                       message: "Make a quick edit and try saving again.",
                       color: .red)
        case .idle:
            EmptyView()
        }
    }

    /// Title + message for the decline status card, specialized per
    /// `ParseDeclineReason`. The diagnoses are heuristic, so the copy stays
    /// honest: "looks like a rep range" rather than "rep ranges aren't
    /// supported" — never a confident wrong claim.
    static func declineTitle(_ reason: ParseDeclineReason?) -> String {
        switch reason {
        case .repRange:         return "Pick a single rep count"
        case .cardio:           return "Cardio isn't logged here yet"
        case .multiExercise:    return "One exercise per line, for now"
        case .incompleteWeight: return "Add reps to that set"
        case .ambiguousTripleX: return "Looks like 5×5×5 — please rephrase"
        case nil:               return "Couldn't read that one yet"
        }
    }

    static func declineMessage(_ reason: ParseDeclineReason?) -> String {
        switch reason {
        case .repRange:
            return "The log stores one rep count per set — try \"bench 135x10\" or \"3x10 @ 135\" instead of \"8-10\"."
        case .cardio:
            return "Strength sets only at launch. Log distance/duration separately for now."
        case .multiExercise:
            return "Put each exercise on its own line — \"bench 135x8\" then \"curl 30x10\"."
        case .incompleteWeight:
            return "Try a shape like bench 135x8 — a weight on its own can't be saved without reps."
        case .ambiguousTripleX:
            return "Try \"bench 5x5\" with a separate weight (\"3x10 @ 135\") so the leading number is unambiguous."
        case nil:
            return "Try a shape like bench 135x8, 3x10 @ 135, or bw x12."
        }
    }

    /// The post-save "start rest" prompt (§4), shown in the saved-status branch when
    /// no timer is running. The countdown is in-app and works without notification
    /// permission; the background alert is asked for in context on first start.
    private var restStartButton: some View {
        Button {
            restTimer.start(seconds: RestTimerPreferences.resolvedDefault(restTimerDefaultSeconds))
        } label: {
            Label("Start rest · \(RestTimerModel.mmss(RestTimerPreferences.resolvedDefault(restTimerDefaultSeconds)))",
                  systemImage: "timer")
                .font(.callout).fontWeight(.semibold)
                .foregroundStyle(Theme.ocean)
        }
        .buttonStyle(.plain)
    }

    /// The active/finished countdown (§4) — rendered independently of `status`
    /// (gated on `restTimer.phase != .idle` in the body) so a new parse or
    /// clarification never hides a running rest.
    @ViewBuilder
    private var restTimerControl: some View {
        switch restTimer.phase {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 12) {
                Image(systemName: "timer").foregroundStyle(Theme.ocean)
                Text("Resting · \(restTimer.display)")
                    .font(.callout).fontWeight(.bold).foregroundStyle(Theme.ink)
                    .monospacedDigit()
                Spacer()
                Button("Stop", action: restTimer.cancel)
                    .font(.caption).buttonStyle(.bordered)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ocean.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .finished:
            HStack(spacing: 12) {
                Label("Rest's over", systemImage: "checkmark.circle.fill")
                    .font(.callout).fontWeight(.bold).foregroundStyle(Theme.kelp)
                Spacer()
                Button("Dismiss", action: restTimer.cancel)
                    .font(.caption).buttonStyle(.bordered)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.kelp.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func statusCard(icon: String, title: String, message: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.steel)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The PR celebration card. Borrows the political onboarding HeroIcon's
    /// circle-with-gold-border treatment to make a PR feel earned without
    /// shouting (no emoji, no confetti). The view also pulses a faint gold
    /// glow on appear so the moment lands even mid-scroll.
    ///
    /// Accessibility: the trophy is decorative; VoiceOver reads "Personal
    /// record: <headline>" as a single element so the gold styling never
    /// becomes the only way a screen reader user knows a PR fired.
    private func achievementCard(_ achievement: Achievement) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.gold.opacity(0.18))
                Circle()
                    .strokeBorder(Theme.gold.opacity(0.65), lineWidth: 1.5)
                Image(systemName: "trophy.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.gold)
            }
            .frame(width: 48, height: 48)
            .shadow(color: Theme.gold.opacity(0.45), radius: 14, y: 6)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("PERSONAL RECORD")
                    .font(.caption2.weight(.heavy))
                    .kerning(1.5)
                    .foregroundStyle(Theme.gold)
                Text(achievement.headline)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.ink)
                Text("Computed honestly from your logged sets.")
                    .font(.footnote)
                    .foregroundStyle(Theme.steel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.gold.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.gold.opacity(0.40), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Personal record: \(achievement.headline)")
    }

    /// FM asked one short question (PR 8). Show it with its suggested replies and
    /// the always-present "Type it manually" escape hatch. Tapping a reply re-parses
    /// the original entry with that reply as context; the round cap lives in the model.
    private func clarificationCard(_ prompt: ClarificationPrompt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Theme.ocean)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick question")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(prompt.message)
                        .font(.footnote)
                        .foregroundStyle(Theme.steel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            FlowLayout(spacing: 8) {
                ForEach(prompt.suggestedReplies, id: \.self) { reply in
                    Button { Task { await model.replyToClarification(reply) } } label: {
                        Text(reply)
                            .font(.caption).fontWeight(.semibold)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.ocean.opacity(model.isParsing ? 0.06 : 0.12), in: Capsule())
                            .foregroundStyle(Theme.ocean.opacity(model.isParsing ? 0.5 : 1))
                    }
                    .buttonStyle(.plain)
                    // While a reply is parsing, lock the chips so quick taps can't
                    // accumulate contradictory replies into one context.
                    .disabled(model.isParsing)
                }

                Button(action: model.typeItManually) {
                    Text("Type it manually")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.steel.opacity(0.12), in: Capsule())
                        .foregroundStyle(Theme.steel)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ocean.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Read-only "last time" hint on the confirm card (§4): the most recent
    /// finished session's sets for this lift, plus a relative "N days ago" — purely
    /// informational, never editable.
    private func lastTimeRow(_ lastTime: LastTime) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.ocean)
            VStack(alignment: .leading, spacing: 3) {
                Text("Last time")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.ink)
                Text("\(Self.lastTimeSummary(lastTime.sets)) · \(Self.relativeDay(lastTime.startedAt))")
                    .font(.footnote)
                    .foregroundStyle(Theme.steel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ocean.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// "135 lb×8, 135 lb×8, 130 lb×6" — a compact load×reps list for the "last
    /// time" hint. Keeps the load *kind* honest (bodyweight / added-weight /
    /// assisted read differently from a plain external load) **and** carries the
    /// unit on weighted sets, since the app treats lb and kg histories as distinct.
    static func lastTimeSummary(_ sets: [LastTimeSet]) -> String {
        sets.map { set in
            let reps = set.reps
            // The stored unit for a weighted set; nil only for genuinely loadless work.
            let unit = set.load.unit?.rawValue ?? ""
            func weighted(_ amount: Double) -> String { "\(formatted(amount)) \(unit)×\(reps)" }
            switch set.load.kind {
            case .bodyweight:    return "BW×\(reps)"
            case .unspecified:   return "—×\(reps)"
            case .external:
                guard let amount = set.load.amount else { return "—×\(reps)" }
                return weighted(amount)
            case .bodyweightPlus:
                guard let amount = set.load.amount else { return "BW×\(reps)" }
                return "BW+\(formatted(amount)) \(unit)×\(reps)"
            case .assisted:
                guard let amount = set.load.amount else { return "asst×\(reps)" }
                return "asst \(formatted(amount)) \(unit)×\(reps)"
            }
        }.joined(separator: ", ")
    }

    /// Cached relative-date formatter (§4 — no per-row allocation). "6 days ago".
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func relativeDay(_ date: Date, now: Date = Date()) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: now)
    }

    /// "135 lb × 8 · warmup · 2 RIR" — only the parts that are present.
    static func summary(for set: SetDraft) -> String {
        var parts: [String] = []
        // reps = 0 is the "not filled in yet" sentinel on a recovered draft; show
        // a dash so the row reads "needs reps", not a literal "× 0".
        let reps = set.reps > 0 ? "\(set.reps)" : "—"
        switch set.loadKind {
        case .bodyweight:
            parts.append("BW × \(reps)")
        case .unspecified:
            parts.append("unspecified × \(reps)")
        case .bodyweightPlus:
            parts.append("BW + \(formatted(set.weight)) \(set.unit.rawValue) × \(reps)")
        case .assisted:
            parts.append("assisted \(formatted(set.weight)) \(set.unit.rawValue) × \(reps)")
        case .external:
            parts.append("\(formatted(set.weight)) \(set.unit.rawValue) × \(reps)")
        }
        if set.setType != .working { parts.append(set.setType.rawValue) }
        if let rir = set.rir { parts.append("\(rir) RIR") }
        return parts.joined(separator: " · ")
    }

    private static func formatted(_ weight: Double) -> String {
        weight.rounded() == weight ? String(Int(weight)) : String(weight)
    }
}

private extension View {
    func fieldPill() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// lb/kg toggle on the confirm card — taps only, so it doesn't fight tab swipes.
private struct WeightUnitToggle: View {
    @Binding var selection: WeightUnit

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WeightUnit.allCases, id: \.self) { unit in
                Button {
                    selection = unit
                } label: {
                    Text(unit.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 34)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .foregroundStyle(selection == unit ? Color.white : Theme.steel)
                        .background(selection == unit ? Theme.ocean : Color.clear,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == unit ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.steel.opacity(0.12), in: Capsule())
    }
}

/// Free Form / Workout Plan — tap segments so horizontal swipes stay on the tab pager.
private struct InputModeToggle: View {
    @Binding var selection: TodayModel.Mode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TodayModel.Mode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(selection == mode ? Color.white : Theme.steel)
                        .background(selection == mode ? Theme.ocean : Color.clear,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.steel.opacity(0.12), in: Capsule())
        .accessibilityLabel("Input mode")
    }
}

/// Small wrapping layout for example chips without introducing a collection view.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(at: CGPoint(x: x, y: y),
                          proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Identifies a plate-calculator sheet by the load it was opened for (so it
/// re-presents when the target changes).
private struct PlateSheetInput: Identifiable {
    let target: Double
    let unit: WeightUnit
    var id: String { "\(target)-\(unit.rawValue)" }
}

/// Scroll targets on Today — confirm card after parse, status on decline/clarify.
private enum TodayScrollAnchor: String, Hashable {
    case confirm
    case status
}

/// A small sheet over the confirm card (§4): given the confirmed load, it shows
/// the per-side plates for a configurable bar. Honest — when the exact target
/// can't be made from standard plates, it says so and shows the nearest. All
/// math is `PlateCalculator`; this view only renders and remembers the bar weight.
private struct PlateCalculatorSheet: View {
    let target: Double
    let unit: WeightUnit

    @Environment(\.dismiss) private var dismiss
    @AppStorage("settings.plateCalc.barWeightLb") private var barWeightLb = 45.0
    @AppStorage("settings.plateCalc.barWeightKg") private var barWeightKg = 20.0

    private var bar: Double { unit == .kg ? barWeightKg : barWeightLb }
    private var loadout: PlateLoadout? {
        PlateCalculator.loadout(target: target, bar: bar,
                                plates: PlateCalculator.defaultPlates(for: unit), unit: unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    LabeledContent("Total on the bar",
                                   value: "\(PlateCalculator.format(target)) \(unit.rawValue)")
                    Picker("Bar", selection: barBinding) {
                        ForEach(barOptions, id: \.self) { weight in
                            Text("\(PlateCalculator.format(weight)) \(unit.rawValue)").tag(weight)
                        }
                    }
                }

                if let loadout {
                    Section("Per side") {
                        Text(PlateCalculator.perSideText(loadout))
                            .font(.title3).fontWeight(.semibold)
                        if !loadout.isExact {
                            // Never silently round: state the nearest-achievable load and
                            // exactly how far off it is.
                            Label(nearestText(loadout), systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.gold)
                        }
                    }
                }
            }
            .navigationTitle("Plate calculator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var barBinding: Binding<Double> {
        Binding(get: { bar }, set: { newValue in
            if unit == .kg { barWeightKg = newValue } else { barWeightLb = newValue }
        })
    }

    private var barOptions: [Double] {
        PlateCalculator.defaultBars(for: unit)
    }

    private func nearestText(_ loadout: PlateLoadout) -> String {
        let achieved = "\(PlateCalculator.format(loadout.achieved)) \(unit.rawValue)"
        if loadout.remainder > 0 {
            return "Can't make it exactly — nearest is \(achieved), \(PlateCalculator.format(loadout.remainder)) \(unit.rawValue) short."
        }
        return "That's below the bar — the bar alone is \(achieved)."
    }
}

