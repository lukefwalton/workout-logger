import SwiftUI
import Charts
import LFWDesignSystem

/// Loads the last 30 days of cardio bouts and computes trends. Self-contained
/// (like SupplementTrendsModel) so it renders in Progress regardless of whether
/// there's any *strength* data — cardio never mixes into the strength charts.
@MainActor
final class CardioTrendsModel: ObservableObject {
    @Published private(set) var weekly: [CardioAnalytics.WeekMinutes] = []
    @Published private(set) var summaries: [CardioAnalytics.ActivitySummary] = []
    @Published private(set) var hasHistory = false
    @Published private(set) var loadFailed = false

    let windowDays = 30
    private let store: WorkoutStore

    init(store: WorkoutStore) { self.store = store }

    func load(now: Date = Date()) {
        do {
            let since = CardioAnalytics.windowStart(today: now, windowDays: windowDays)
            let entries = try store.cardioEntries(since: since)
            weekly = CardioAnalytics.weeklyMinutes(entries: entries, today: now, windowDays: windowDays)
            summaries = CardioAnalytics.activitySummaries(entries: entries, today: now, windowDays: windowDays)
            hasHistory = !entries.isEmpty
            loadFailed = false
        } catch {
            // Keep whatever was last shown rather than rendering "no data" over a read
            // failure (same rationale as SupplementTrendsModel).
            loadFailed = true
        }
    }
}

/// The "Cardio" section on the Progress tab: weekly minutes stacked by activity
/// over the last 30 days, plus per-activity totals. Distances are shown in the
/// units they were logged in — never converted.
struct CardioTrendsView: View {
    @StateObject private var model: CardioTrendsModel
    private let appTab: AppTab

    init(store: WorkoutStore, appTab: AppTab) {
        self.appTab = appTab
        _model = StateObject(wrappedValue: CardioTrendsModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cardio").font(.headline).foregroundStyle(Theme.ink)
            Text("Last \(model.windowDays) days").font(.caption).foregroundStyle(Theme.steel)

            if model.loadFailed {
                Label("Couldn't load cardio trends.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(LFWColors.danger)
            } else if !model.hasHistory {
                Text("Log a run or a ride on the Today tab and it will trend here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                if model.weekly.isEmpty {
                    // Bouts exist but none carried a duration — say so instead of
                    // rendering an empty chart as if nothing happened.
                    Text("Add durations to see weekly minutes.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    minutesChart
                }
                ForEach(model.summaries) { summary in
                    summaryRow(summary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.deepSea.opacity(0.08), radius: 16, y: 8)
        .task { model.load() }
        // Tabs live in a non-lazy stack, so `.task` fires only once at launch;
        // reload when the Progress tab is (re)shown (same contract as the
        // supplement card).
        .onChange(of: appTab) { _, tab in
            if tab == .progress { model.load() }
        }
    }

    private var minutesChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Weekly minutes — duration-logged bouts · per ISO week")
                .font(.caption2).foregroundStyle(Theme.steel)
            Chart(model.weekly) { bar in
                BarMark(x: .value("Week", bar.weekStart), y: .value("Minutes", bar.minutes))
                    .foregroundStyle(by: .value("Activity", bar.activity))
                    .accessibilityLabel("\(bar.activity), week of \(ChartDateLabel.string(bar.weekStart))")
                    // Announce through the shared duration formatter ("7m 30s",
                    // "45s") — rounding to whole minutes would misstate short
                    // bouts ("0.33 min" as "0 minutes"), and this card never
                    // fabricates a metric. A rendered bar always has minutes > 0,
                    // so the nil fallback is unreachable in practice.
                    .accessibilityValue(CardioFormat.duration(Int((bar.minutes * 60).rounded())) ?? "0 seconds")
            }
            .frame(height: 200)
        }
        .padding(.bottom, 6)
    }

    private func summaryRow(_ summary: CardioAnalytics.ActivitySummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: CardioActivityIcon.symbol(forActivity: summary.activity))
                .foregroundStyle(Theme.ocean)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.activity).fontWeight(.semibold).foregroundStyle(Theme.ink)
                Text(Self.detail(for: summary))
                    .font(.caption).foregroundStyle(Theme.steel)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// "6 bouts · 3h 10m · 12 mi · 5 km" — only the parts present, one distance
    /// segment per logged unit (never converted).
    static func detail(for summary: CardioAnalytics.ActivitySummary) -> String {
        var parts = ["\(summary.bouts) bout\(summary.bouts == 1 ? "" : "s")"]
        if let duration = CardioFormat.duration(summary.totalSeconds) { parts.append(duration) }
        for unit in CardioDistanceUnit.allCases {
            if let total = summary.distanceByUnit[unit], total > 0 {
                parts.append("\(formattedTotal(total)) \(unit.label)")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Aggregated distances round to one decimal: a sum of binary floats
    /// (1.1 + 2.2) must never render as "3.3000000000000003 mi". Verbatim
    /// single logged values still go through `CardioFormat.distance`; this is
    /// for totals only.
    private static func formattedTotal(_ value: Double) -> String {
        let rounded = String(format: "%.1f", value)
        return rounded.hasSuffix(".0") ? String(rounded.dropLast(2)) : rounded
    }
}
