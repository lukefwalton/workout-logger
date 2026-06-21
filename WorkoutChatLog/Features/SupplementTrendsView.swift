import SwiftUI
import Charts

/// Loads the last 30 days of supplement intake and computes trends. Self-contained
/// so it can render in Progress regardless of whether there's any *workout* data.
@MainActor
final class SupplementTrendsModel: ObservableObject {
    @Published private(set) var trends: [SupplementAnalytics.Trend] = []
    @Published private(set) var gramsSeriesByID: [Int64: [SupplementAnalytics.GramsPoint]] = [:]
    @Published private(set) var hasHistory = false
    @Published private(set) var loadFailed = false

    let windowDays = 30
    private let store: WorkoutStore

    init(store: WorkoutStore) { self.store = store }

    func load(now: Date = Date()) {
        do {
            let supplements = try store.supplements()
            let since = SupplementDay.key(daysAgo: windowDays - 1, from: now)
            let history = try store.supplementHistory(sinceDay: since)

            trends = SupplementAnalytics.trends(supplements: supplements, history: history,
                                                today: now, windowDays: windowDays)
            var grams: [Int64: [SupplementAnalytics.GramsPoint]] = [:]
            for supplement in supplements where supplement.tracksGrams {
                let series = SupplementAnalytics.gramsSeries(supplementID: supplement.id, history: history,
                                                             today: now, windowDays: windowDays)
                if !series.isEmpty { grams[supplement.id] = series }
            }
            gramsSeriesByID = grams
            hasHistory = !history.isEmpty
            loadFailed = false
        } catch {
            // Keep whatever was last shown rather than rendering "no data" over a read
            // failure (which, post-migration, would be misleading).
            loadFailed = true
        }
    }
}

/// The "Supplements" section on the Progress tab: per-supplement adherence + current
/// streak over the last 30 days, plus a protein-grams trend when there's data.
struct SupplementTrendsView: View {
    @StateObject private var model: SupplementTrendsModel

    init(store: WorkoutStore) {
        _model = StateObject(wrappedValue: SupplementTrendsModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supplements").font(.headline).foregroundStyle(Theme.ink)
            Text("Last \(model.windowDays) days").font(.caption).foregroundStyle(Theme.steel)

            if model.loadFailed {
                Label("Couldn't load supplement trends.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.red)
            } else if model.trends.isEmpty {
                Text("Add supplements on the Today tab to track them here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !model.hasHistory {
                Text("Check one off on the Today tab and your adherence will trend here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(model.trends) { trend in
                    trendRow(trend)
                    if let series = model.gramsSeriesByID[trend.supplementID], series.count >= 2 {
                        gramsChart(series, name: trend.name)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.deepSea.opacity(0.08), radius: 16, y: 8)
        .task { model.load() }
    }

    private func trendRow(_ trend: SupplementAnalytics.Trend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(trend.name).fontWeight(.semibold).foregroundStyle(Theme.ink)
                Spacer()
                if trend.currentStreak > 0 {
                    Label("\(trend.currentStreak)", systemImage: "flame.fill")
                        .font(.caption).fontWeight(.bold)
                        .foregroundStyle(Theme.gold)
                }
                Text("\(trend.daysTaken)/\(trend.windowDays) days")
                    .font(.caption).foregroundStyle(Theme.steel)
            }
            ProgressView(value: trend.adherence)
                .tint(Theme.kelp)
        }
        .padding(.vertical, 4)
    }

    private func gramsChart(_ series: [SupplementAnalytics.GramsPoint], name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(name) — grams").font(.caption2).foregroundStyle(Theme.steel)
            Chart(series) { point in
                LineMark(x: .value("Date", point.day), y: .value("Grams", point.grams))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.ocean)
                PointMark(x: .value("Date", point.day), y: .value("Grams", point.grams))
                    .foregroundStyle(Theme.ocean)
            }
            .frame(height: 120)
        }
        .padding(.bottom, 6)
    }
}
