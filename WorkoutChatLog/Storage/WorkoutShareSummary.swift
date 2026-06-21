import Foundation

// Deterministic, on-device formatting of training history into the Markdown
// "AI share" prompt (table + optional trend summary). Pure transformation over
// `WorkoutSetHistoryRow` — no database access — so it lives apart from the store.
// `WorkoutStore.aiSharePrompt` fetches the rows and calls in here.

enum WorkoutShareSummary {
    static func aiPrompt(rows: [WorkoutSetHistoryRow],
                         days: Int,
                         includeNotes: Bool = false,
                         includeTrends: Bool = false) -> String {
        guard !rows.isEmpty else {
            return """
            Here is my recent training log. I do not have workout sets in this export window yet.

            Data window: last \(days) days
            """
        }

        let notesColumn = includeNotes ? " | Notes" : ""
        var lines = [
            "Here is my recent training log.",
            "",
            "Data window: last \(days) days",
            "Format: one row per logged set. This payload was prepared locally; I chose to share it.",
            "",
        ]

        if includeTrends {
            lines.append(contentsOf: trendSection(rows: rows))
            lines.append("")
        }

        lines.append(contentsOf: [
            "| Date | Exercise | Set | Load | Reps | RIR | Type\(notesColumn) |",
            "| --- | --- | ---: | --- | ---: | --- | ---\(includeNotes ? " | ---" : "") |"
        ])

        for row in rows {
            let rir = row.rir.map(String.init) ?? ""
            var cells = [
                row.startedAt,
                row.exerciseName,
                String(row.setIndex),
                row.load.displayText,
                String(row.reps),
                rir,
                row.setType.rawValue
            ]
            if includeNotes { cells.append(row.notes ?? "") }
            lines.append("| " + cells.map(escapeMarkdownTableCell).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private struct Trend {
        let exercise: String
        let sets: Int
        let sessions: Int
        let averageLoad: String
        let averageReps: String
        let averageRIR: String
        let loadTrend: String
    }

    private static func trendSection(rows: [WorkoutSetHistoryRow]) -> [String] {
        let trends = rows
            .grouped(by: { $0.exerciseName })
            .map { trend(for: $0.key, rows: $0.value) }
            .sorted { $0.exercise.localizedCaseInsensitiveCompare($1.exercise) == .orderedAscending }

        var lines = [
            "## Deterministic Trend Summary",
            "",
            "| Exercise | Sets | Sessions | Avg Load | Avg Reps | Avg RIR | Load Trend |",
            "| --- | ---: | ---: | --- | ---: | ---: | --- |"
        ]
        for trend in trends {
            lines.append("| " + [
                trend.exercise,
                String(trend.sets),
                String(trend.sessions),
                trend.averageLoad,
                trend.averageReps,
                trend.averageRIR,
                trend.loadTrend
            ].map(escapeMarkdownTableCell).joined(separator: " | ") + " |")
        }
        return lines
    }

    private static func trend(for exercise: String, rows: [WorkoutSetHistoryRow]) -> Trend {
        let sessions = Set(rows.map(\.sessionID)).count
        return Trend(exercise: exercise,
                     sets: rows.count,
                     sessions: sessions,
                     averageLoad: averageLoadText(rows),
                     averageReps: formattedAverage(rows.map { Double($0.reps) }),
                     averageRIR: formattedAverage(rows.compactMap { $0.rir.map(Double.init) }),
                     loadTrend: loadTrendText(rows))
    }

    private static func averageLoadText(_ rows: [WorkoutSetHistoryRow]) -> String {
        let amounts = comparableLoadAmounts(rows)
        guard !amounts.values.isEmpty else { return "n/a" }
        return "\(formattedAverage(amounts.values)) \(amounts.unit.rawValue)"
    }

    private static func loadTrendText(_ rows: [WorkoutSetHistoryRow]) -> String {
        let chronological = rows.sorted {
            if $0.startedAt == $1.startedAt { return $0.setID < $1.setID }
            return $0.startedAt < $1.startedAt
        }
        let amounts = comparableLoadAmounts(chronological)
        // The "never silently convert" doctrine: if loads span mixed units, surface why
        // the trend was omitted rather than reading as "n/a" alongside the genuinely-empty
        // case. (Conversion would invent a number — see the calorie estimate gate, §1.)
        if amounts.mixedUnits { return "(mixed units — trend omitted)" }
        guard amounts.values.count >= 2 else { return "n/a" }
        let split = max(1, amounts.values.count / 2)
        let early = average(amounts.values.prefix(split).map { $0 })
        let recent = average(amounts.values.suffix(amounts.values.count - split).map { $0 })
        let delta = recent - early
        guard abs(delta) >= 0.05 else { return "flat" }
        let sign = delta > 0 ? "+" : ""
        return "\(sign)\(formatted(delta)) \(amounts.unit.rawValue)"
    }

    private static func comparableLoadAmounts(_ rows: [WorkoutSetHistoryRow]) -> (values: [Double], unit: WeightUnit, mixedUnits: Bool) {
        let loads = rows.compactMap { row -> (Double, WeightUnit)? in
            guard [.external, .bodyweightPlus, .assisted].contains(row.load.kind),
                  let amount = row.load.amount,
                  let unit = row.load.unit else { return nil }
            return (amount, unit)
        }
        guard let unit = loads.first?.1 else { return ([], .lb, false) }
        guard loads.allSatisfy({ $0.1 == unit }) else { return ([], .lb, true) }
        return (loads.map(\.0), unit, false)
    }

    private static func formattedAverage(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        return formatted(average(values))
    }

    private static func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private static func formatted(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded() == rounded ? String(Int(rounded)) : String(rounded)
    }

    private static func escapeMarkdownTableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}

private extension Sequence {
    func grouped<Key: Hashable>(by key: (Element) -> Key) -> [Key: [Element]] {
        Dictionary(grouping: self, by: key)
    }
}
