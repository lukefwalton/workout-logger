import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The one tab with real content this step: it reads from the spine, which is
/// proof the database opened, migrated, and seeded. Editing the exercise muscle
/// map and the analytics policy comes later; for now these values are shown
/// read-only so the spine is visible end to end.
struct SettingsView: View {
    let store: WorkoutStore

    /// This tab exists to prove the spine opened and seeded. A read failure must
    /// look like a failure — not like an empty library — so it gets its own
    /// state rather than collapsing to "—".
    private enum LibraryState: Equatable {
        case loading
        case loaded(Int)
        case failed(String)
    }

    @State private var library: LibraryState = .loading
    @State private var showAddExercisePrompt = false
    @State private var newExerciseName = ""
    @AppStorage("settings.includeTrendSummaryInAIShare") private var includeTrendSummaryInAIShare = true
    @AppStorage("settings.includeNotesInFullExport") private var includeNotesInFullExport = true
    /// PR 10: opt-in Apple Health. The toggle is **user intent** (default off); the
    /// manual bodyweight is the fallback when HealthKit isn't available/granted. The
    /// same `manualBodyweightKg` value powers the PR 11 calorie estimate — both feature
    /// PRs deliberately use one key (CaloriePreferences.bodyweightKgKey ==
    /// HealthPreferences.manualBodyweightKgKey), so there's one bodyweight field, not two.
    @AppStorage(HealthPreferences.saveWorkoutsToHealthKey) private var saveWorkoutsToHealth = false
    @AppStorage(HealthPreferences.manualBodyweightKgKey) private var manualBodyweightKg = 0.0
    /// The user's preferred default weight unit (lb/kg). Drives how an
    /// unannotated `100x5` is parsed; the app never silently converts stored
    /// sets, so switching this affects new entries only — old rows keep their
    /// original unit (see WeightUnit doctrine).
    @AppStorage(UnitPreferences.defaultUnitKey) private var defaultUnitRaw = WeightUnit.lb.rawValue
    /// Default rest length (seconds) for the Today rest timer (spec §4). Stored as a
    /// Double for `@AppStorage`; 0/unset resolves to `defaultDurationSeconds`.
    @AppStorage(RestTimerPreferences.defaultDurationKey) private var restTimerDefaultSeconds = 0.0
    @State private var healthSetupFailed = false
    private let health = HealthWorkoutCoordinator()
    @State private var showFullExportConfirmation = false
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var exportError: String?
    @State private var showImporter = false
    @State private var pendingImport: PendingImport?
    @State private var importMessage: String?
    private let policy = AnalyticsPolicy.default

    /// A parsed-but-not-yet-applied import: the file plus a dry-run summary shown
    /// for confirmation before anything is written.
    private struct PendingImport: Identifiable {
        let id = UUID()
        let url: URL
        let summary: ImportSummary
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Library") {
                    LabeledContent("Exercises in library") {
                        switch library {
                        case .loading:
                            ProgressView()
                        case .loaded(let count):
                            Text("\(count)")
                        case .failed:
                            Label("Read failed", systemImage: "exclamationmark.triangle")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.red)
                        }
                    }
                    NavigationLink {
                        ExerciseLibraryView(store: store)
                    } label: {
                        Label("Manage exercises", systemImage: "list.bullet")
                    }
                    Button {
                        newExerciseName = ""
                        showAddExercisePrompt = true
                    } label: {
                        Label("Add exercise", systemImage: "plus.circle")
                    }
                    if case .failed = library {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Couldn't read the exercise library.")
                                .font(.footnote)
                            #if DEBUG
                            if case .failed(let message) = library {
                                Text(message)
                                    .font(.caption2)
                                    .monospaced()
                                    .foregroundStyle(.secondary)
                            }
                            #endif
                        }
                    }
                }

                Section {
                    Picker("Default unit", selection: defaultUnitSelection) {
                        Text("Pounds (lb)").tag(WeightUnit.lb)
                        Text("Kilograms (kg)").tag(WeightUnit.kg)
                    }
                } header: {
                    Text("Units")
                } footer: {
                    Text("How an unannotated weight like \"100x5\" is read. The app never silently converts stored sets, so switching this affects new entries only — your history keeps the unit it was logged with.")
                }

                Section {
                    LabeledContent("Hard-set RIR threshold", value: "≤ \(policy.hardSetRIRThreshold)")
                    LabeledContent("Count unknown RIR as hard", value: policy.countNullRIRAsHard ? "Yes" : "No")
                } header: {
                    Text("Analytics policy")
                } footer: {
                    Text("How \"hard sets\" are counted. Editable later — kept explicit so the number never becomes a silent lie.")
                }

                Section {
                    Button {
                        shareLastThirtyDaysWithAI()
                    } label: {
                        Label("Share last 30 days with AI", systemImage: "sparkles")
                    }

                    Toggle("Include trend summary in AI share", isOn: $includeTrendSummaryInAIShare)

                    Toggle("Include notes in full export", isOn: $includeNotesInFullExport)

                    Button {
                        showFullExportConfirmation = true
                    } label: {
                        Label("Export all workout data", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showImporter = true
                    } label: {
                        Label("Restore from backup (JSON)", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("AI share creates a markdown prompt without notes, optionally with deterministic averages and trends. Full export creates a versioned JSON file for backup or portability, then iOS lets you choose the destination. Your workout database is also included in iCloud Backup automatically when that's enabled on your iPhone, so a new device restored from backup brings your history with it.")
                }

                Section {
                    Toggle("Save workouts to Apple Health", isOn: $saveWorkoutsToHealth)
                        .onChange(of: saveWorkoutsToHealth) { _, enabled in
                            // System permission ≠ user intent: only ask once the user
                            // turns the toggle on.
                            guard enabled else { return }
                            healthSetupFailed = false
                            Task { @MainActor in
                                // Revert the toggle unless workout sharing is actually
                                // authorized — covers Health-unavailable, a request
                                // error, and an explicit workout-sharing denial (share
                                // status is queryable, so we don't leave it reading
                                // "on" for a feature that would silently no-op).
                                if await health.requestAuthorization() == false {
                                    saveWorkoutsToHealth = false
                                    healthSetupFailed = true
                                }
                            }
                        }
                    if healthSetupFailed {
                        Label("Apple Health access wasn't granted. Enable it in the Settings app, then try again.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // One bodyweight field, shared by Apple Health (read fallback) and the
                    // PR 11 calorie estimate (same UserDefaults key). Storage is always kg
                    // (HealthKit + CalorieEstimate expect kg); the field shows + accepts
                    // the user's preferred unit and converts at the edge.
                    HStack {
                        Text("Bodyweight")
                        Spacer()
                        // 0..2 fractional digits: bodyweight is meaningful to
                        // ~0.02 lb / 0.01 kg; more digits would imply spurious
                        // precision through the kg<->lb conversion.
                        TextField("—", value: bodyweightDisplay, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                        Text(defaultUnitSelection.wrappedValue.rawValue).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Apple Health & calorie estimate")
                } footer: {
                    Text("Optional and on-device. When on, finishing a workout saves one strength session to Apple Health — never your calorie estimate. Your bodyweight (entered here or read from Health) powers the rough per-session calorie estimate (MET × bodyweight × duration) shown in History, and never leaves your phone.")
                }

                Section {
                    Picker("Default rest", selection: restTimerSelection) {
                        ForEach(RestTimerPreferences.durationOptions, id: \.self) { seconds in
                            Text(RestTimerModel.mmss(seconds)).tag(seconds)
                        }
                    }
                } header: {
                    Text("Rest timer")
                } footer: {
                    Text("The default countdown started from the Today tab after you log a set. A notification when rest ends is asked for the first time you start a timer — never at launch — and the countdown works even if you decline.")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    Text("Local-first and on-device: no account, no server, no tracking. Your data stays on this phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                } footer: {
                    Text("Not medical or coaching advice. Private Workout Logger tracks what you log; it doesn't diagnose, treat, or prescribe.")
                }
            }
            .navigationTitle("Settings")
            .alert("Add exercise", isPresented: $showAddExercisePrompt) {
                TextField("Exercise name", text: $newExerciseName)
                    .textInputAutocapitalization(.words)
                Button("Add") {
                    addExercise()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Add a custom lift to your local exercise library.")
            }
            .confirmationDialog("Export all workout data?",
                                isPresented: $showFullExportConfirmation,
                                titleVisibility: .visible) {
                Button("Export and choose destination") {
                    exportAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(fullExportConfirmationMessage)
            }
            .sheet(isPresented: $showShareSheet) {
                ActivityView(activityItems: shareItems)
            }
            .alert("Export failed", isPresented: Binding(get: { exportError != nil },
                                                          set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                handleImportSelection(result)
            }
            .alert("Restore backup?", isPresented: Binding(get: { pendingImport != nil },
                                                           set: { if !$0 { pendingImport = nil } }),
                   presenting: pendingImport) { pending in
                Button("Restore") { commitImport(pending) }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            } message: { pending in
                Text(previewMessage(pending.summary))
            }
            .alert("Restore", isPresented: Binding(get: { importMessage != nil },
                                                   set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
            .task {
                do {
                    library = .loaded(try store.exerciseCount())
                } catch {
                    library = .failed(String(describing: error))
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    /// Bridges the picker's `Int` seconds to the `Double`-backed `@AppStorage`,
    /// resolving an unset/off-menu stored value to the sensible default.
    private var restTimerSelection: Binding<Int> {
        Binding(get: { RestTimerPreferences.resolvedDefault(restTimerDefaultSeconds) },
                set: { restTimerDefaultSeconds = Double($0) })
    }

    /// Bridges the unit picker (typed `WeightUnit`) to the `String`-backed
    /// `@AppStorage`. Falls back to `.lb` on an unrecognized stored value so a
    /// hand-edited Defaults plist can't break the app.
    private var defaultUnitSelection: Binding<WeightUnit> {
        Binding(get: { UnitPreferences.resolved(defaultUnitRaw) },
                set: { defaultUnitRaw = $0.rawValue })
    }

    /// Bodyweight `TextField` binding that displays + accepts the user's
    /// preferred unit while keeping storage in kg. A `0` round-trips to `0`
    /// regardless of unit so an unset field stays "—".
    private var bodyweightDisplay: Binding<Double> {
        Binding(
            get: {
                let unit = UnitPreferences.resolved(defaultUnitRaw)
                return BodyweightConversion.display(kg: manualBodyweightKg, in: unit)
            },
            set: { newValue in
                let unit = UnitPreferences.resolved(defaultUnitRaw)
                manualBodyweightKg = BodyweightConversion.storedKg(from: newValue, in: unit)
            }
        )
    }

    private var fullExportConfirmationMessage: String {
        let notes = includeNotesInFullExport ? "including workout and set notes" : "excluding workout and set notes"
        return "This creates a local JSON file with all sessions, exercises, loads, reps, RIR, and source text, \(notes). You choose where it goes next."
    }

    @MainActor
    private func addExercise() {
        do {
            _ = try store.addExercise(named: newExerciseName)
            library = .loaded(try store.exerciseCount())
            newExerciseName = ""
        } catch {
            library = .failed(String(describing: error))
        }
    }

    @MainActor
    private func shareLastThirtyDaysWithAI() {
        do {
            shareItems = [try store.aiSharePrompt(lastDays: 30,
                                                  includeNotes: false,
                                                  includeTrends: includeTrendSummaryInAIShare)]
            showShareSheet = true
        } catch {
            exportError = String(describing: error)
        }
    }

    @MainActor
    private func exportAllData() {
        do {
            shareItems = [try store.writeDataExport(includeNotes: includeNotesInFullExport)]
            showShareSheet = true
        } catch {
            exportError = String(describing: error)
        }
    }

    /// Parse the chosen file as a dry-run first — import is propose-then-confirm at
    /// the file level: preview the summary, then the user confirms before any write.
    @MainActor
    private func handleImportSelection(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            pendingImport = PendingImport(url: url, summary: try store.importData(fromFileAt: url, dryRun: true))
        } catch {
            importMessage = "Couldn't read that file. Make sure it's a Private Workout Logger JSON export."
        }
    }

    @MainActor
    private func commitImport(_ pending: PendingImport) {
        pendingImport = nil
        let scoped = pending.url.startAccessingSecurityScopedResource()
        defer { if scoped { pending.url.stopAccessingSecurityScopedResource() } }
        do {
            let summary = try store.importData(fromFileAt: pending.url)
            library = .loaded(try store.exerciseCount())
            let skipped = summary.skippedSessions > 0 ? " (\(summary.skippedSessions) already present)" : ""
            importMessage = "Restored \(summary.addedSessions) workout\(summary.addedSessions == 1 ? "" : "s") and \(summary.addedSets) sets\(skipped)."
        } catch {
            importMessage = "Restore failed — no changes were made."
        }
    }

    private func previewMessage(_ summary: ImportSummary) -> String {
        guard !summary.isEmpty else { return "This backup's data is already present — nothing to add." }
        var parts = ["Add \(summary.addedSessions) workout\(summary.addedSessions == 1 ? "" : "s") and \(summary.addedSets) sets"]
        if summary.addedExercises > 0 { parts.append("\(summary.addedExercises) new exercise\(summary.addedExercises == 1 ? "" : "s")") }
        if summary.skippedSessions > 0 { parts.append("\(summary.skippedSessions) already present") }
        return parts.joined(separator: " · ") + "."
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
