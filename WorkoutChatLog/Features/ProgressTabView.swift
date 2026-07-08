import SwiftUI
import Charts
import LFWDesignSystem

/// Named `ProgressTabView` to avoid colliding with SwiftUI's `ProgressView`.
/// Swift Charts over deterministic, canonical-only aggregates (`ProgressAnalytics`).
///
/// NOTE: written correct-by-inspection — chart rendering needs an Xcode/device
/// pass (no simulator here).
struct ProgressTabView: View {
    @StateObject private var model: ProgressModel
    private let store: WorkoutStore
    @Binding private var appTab: AppTab

    init(store: WorkoutStore, appTab: Binding<AppTab>) {
        self.store = store
        _model = StateObject(wrappedValue: ProgressModel(store: store))
        _appTab = appTab
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Progress")
                .task { await model.load() }
                .onChange(of: appTab) { _, tab in
                    guard tab == .progress else { return }
                    Task { await model.load() }
                }
                .refreshable { await model.load() }
        }
    }

    // The workout charts handle their own loading/empty/failed states inline; the
    // cardio and supplement trends always render below them — so someone tracking
    // only cardio or supplements still has a Progress tab worth opening. Order
    // reads training → conditioning → habits.
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                workoutSection
                CardioTrendsView(store: store, appTab: appTab)
                SupplementTrendsView(store: store, appTab: appTab)
            }
            .padding(20)
        }
        .background(Theme.paper.ignoresSafeArea())
    }

    @ViewBuilder
    private var workoutSection: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        case .empty:
            workoutsEmptyCard
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load progress", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .loaded:
            loaded
        }
    }

    private var workoutsEmptyCard: some View {
        // Shared hero empty state (prominent + gold eyebrow) on the family card
        // surface, instead of a locally re-derived hero glyph.
        LFWEmptyState(
            symbol: "chart.line.uptrend.xyaxis",
            title: "Charts arrive with your first sets.",
            message: "Log a few workouts and your e1RM, volume, and per-muscle trends will chart here.",
            eyebrow: "Fresh slate",
            prominent: true
        )
        .lfwCard(fill: .white, padding: 0)
    }

    private var loaded: some View {
        VStack(alignment: .leading, spacing: 18) {
            exercisePicker
            Toggle("Exclude off-days & deloads from trends", isOn: $model.excludeNonRepresentative)
                .font(.subheadline)
                .tint(Theme.ocean)

            if let exercise = model.selectedExercise {
                if exercise.isBodyweight {
                    chartCard("Reps — \(exercise.name)", "Top-set reps per workout") {
                        lineChart(model.repsSeries())
                    }
                } else {
                    chartCard("Est. 1RM — \(exercise.name)", "Epley, top working set per workout") {
                        lineChart(model.e1RMSeries())
                    }
                    chartCard("Volume — \(exercise.name)", "External load × reps per workout") {
                        volumeChart(model.volumeSeries())
                    }
                }
            }

            chartCard("Weekly hard sets by muscle", "Primary muscle · per ISO week") {
                muscleChart(model.muscleWeeklyHardSets())
            }
        }
    }

    private var exercisePicker: some View {
        Picker("Exercise", selection: $model.selectedExerciseID) {
            ForEach(model.exercises) { exercise in
                Text(exercise.name).tag(Optional(exercise.id))
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func lineChart(_ data: [ProgressAnalytics.SessionValue]) -> some View {
        if data.count < 2 {
            notEnoughData
        } else {
            Chart(data) { point in
                // Hide the line's per-segment accessibility element so VoiceOver
                // doesn't read each datapoint twice (once for LineMark, once
                // for PointMark) — only the discrete points get labels.
                LineMark(x: .value("Date", point.startedAt), y: .value("Value", point.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.ocean)
                    .accessibilityHidden(true)
                PointMark(x: .value("Date", point.startedAt), y: .value("Value", point.value))
                    .foregroundStyle(Theme.ocean)
                    .accessibilityLabel(Self.dateAccessibilityLabel(point.startedAt))
                    .accessibilityValue(Self.formatted(point.value))
            }
            .frame(height: 200)
        }
    }

    @ViewBuilder
    private func volumeChart(_ data: [ProgressAnalytics.SessionValue]) -> some View {
        if data.isEmpty {
            notEnoughData
        } else {
            Chart(data) { point in
                BarMark(x: .value("Date", point.startedAt), y: .value("Volume", point.value))
                    .foregroundStyle(Theme.ocean.gradient)
                    .accessibilityLabel(Self.dateAccessibilityLabel(point.startedAt))
                    .accessibilityValue("\(Self.formatted(point.value)) volume")
            }
            .frame(height: 180)
        }
    }

    @ViewBuilder
    private func muscleChart(_ data: [ProgressAnalytics.MuscleWeekCount]) -> some View {
        if data.isEmpty {
            notEnoughData
        } else {
            Chart(data) { bar in
                BarMark(x: .value("Week", bar.weekStart), y: .value("Hard sets", bar.hardSets))
                    .foregroundStyle(by: .value("Muscle", bar.muscle))
                    .accessibilityLabel("\(bar.muscle), week of \(Self.dateAccessibilityLabel(bar.weekStart))")
                    .accessibilityValue("\(bar.hardSets) hard set\(bar.hardSets == 1 ? "" : "s")")
            }
            .frame(height: 220)
        }
    }

    // Per-mark accessibility — VoiceOver reads each datapoint with its date +
    // value instead of the color/position alone. Closes the cross-cutting
    // audit gap that "color-coded charts had no audio graph". The formatter is
    // the shared cached one (ChartDateLabel) — no per-mark allocation.
    private static func dateAccessibilityLabel(_ date: Date) -> String {
        ChartDateLabel.string(date)
    }

    private static func formatted(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    private var notEnoughData: some View {
        Text("Not enough data yet.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
    }

    private func chartCard<Content: View>(_ title: String, _ subtitle: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(Theme.ink)
            Text(subtitle).font(.caption).foregroundStyle(Theme.steel)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.deepSea.opacity(0.08), radius: 16, y: 8)
    }
}
