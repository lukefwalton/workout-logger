import WidgetKit
import SwiftUI

/// Read-only Home Screen widget: the current open workout's set count while one is
/// active, otherwise the last finished workout. It reads the shared App Group store
/// through `WorkoutWidgetReader` (its own connection, SELECTs only) and **never
/// writes**. The app nudges it via `WidgetCenter.reloadAllTimelines()` after each
/// save/finish; the timeline policy below is just a backstop cadence.
///
/// NOT COMPILED HERE (Linux, no WidgetKit SDK / Xcode). Correct-by-inspection;
/// first real verification is an on-device render.
struct WorkoutWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetWorkoutSnapshot
}

struct WorkoutWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WorkoutWidgetEntry {
        WorkoutWidgetEntry(date: Date(), snapshot: .current(sets: 3))
    }

    func getSnapshot(in context: Context, completion: @escaping (WorkoutWidgetEntry) -> Void) {
        completion(WorkoutWidgetEntry(date: Date(), snapshot: WorkoutWidgetReader.snapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkoutWidgetEntry>) -> Void) {
        let entry = WorkoutWidgetEntry(date: Date(), snapshot: WorkoutWidgetReader.snapshot())
        let next = Date().addingTimeInterval(60 * 60)   // hourly backstop
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct WorkoutWidgetView: View {
    var entry: WorkoutWidgetEntry

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch entry.snapshot {
            case .current(let sets):
                Label("Current workout", systemImage: "figure.strengthtraining.traditional")
                    .font(.caption).fontWeight(.bold).foregroundStyle(Color.brandOcean)
                Text("\(sets) set\(sets == 1 ? "" : "s")")
                    .font(.title2).fontWeight(.bold)
                Text("in progress").font(.caption).foregroundStyle(.secondary)

            case .last(let name, let endedAt, let sets):
                Label("Last workout", systemImage: "clock.arrow.circlepath")
                    .font(.caption).fontWeight(.bold).foregroundStyle(Color.brandOcean)
                Text((name?.isEmpty == false) ? name! : Self.dateFormatter.string(from: endedAt))
                    .font(.headline).lineLimit(1)
                Text("\(sets) set\(sets == 1 ? "" : "s") · \(Self.dateFormatter.string(from: endedAt))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)

            case .empty:
                Label("Private Workout Logger", systemImage: "dumbbell.fill")
                    .font(.caption).fontWeight(.bold).foregroundStyle(Color.brandOcean)
                Text("Log your first set").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tapping the widget opens the app on the Today tab (quick log).
        .widgetURL(URL(string: "workoutchatlog://today"))
    }
}

private extension Color {
    /// The family ocean accent (`LFWColors.ocean`, #1D75BC), inlined because the widget
    /// target doesn't link LFWDesignSystem. Without this the widget's `.tint` labels fell
    /// back to system blue instead of the brand accent. Keep in sync with the palette.
    static let brandOcean = Color(red: 0x1D / 255, green: 0x75 / 255, blue: 0xBC / 255)
}

struct WorkoutWidget: Widget {
    let kind = "WorkoutWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorkoutWidgetProvider()) { entry in
            WorkoutWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Private Workout Logger")
        .description("Your current or last workout, at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
