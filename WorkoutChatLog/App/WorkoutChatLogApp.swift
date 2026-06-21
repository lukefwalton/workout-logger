import SwiftUI

@main
struct WorkoutChatLogApp: App {
    /// One store for the whole app. Built once at launch: open SQLite, migrate,
    /// seed. Held as state so the UI can show a loading or error state instead
    /// of crashing if the on-device database can't be opened.
    @AppStorage("hasCompletedWorkoutOnboarding") private var hasCompletedOnboarding = false
    @State private var store: WorkoutStore?
    @State private var startupError: String?
    @State private var selectedTab: AppTab = .today

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    if hasCompletedOnboarding {
                        RootTabView(store: store, tab: $selectedTab)
                    } else {
                        WorkoutOnboardingView {
                            hasCompletedOnboarding = true
                        }
                    }
                } else if let startupError {
                    StartupErrorView(message: startupError)
                } else {
                    ProgressView("Opening your log…")
                        .task { await bootstrap() }
                }
            }
            .tint(Theme.tint)
            .fontDesign(.rounded)
            // Widget quick-log deep link (workoutchatlog://today) → jump to Today.
            .onOpenURL { url in
                if url.scheme == "workoutchatlog", url.host == "today" {
                    selectedTab = .today
                }
            }
        }
    }

    @MainActor
    private func bootstrap() {
        do {
            store = try AppDatabase.makeStore()
        } catch {
            startupError = String(describing: error)
        }
    }
}

/// Shown only if the local database fails to open — there is no server to fall
/// back to, so the failure is surfaced honestly rather than hidden.
private struct StartupErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't open your log", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 10) {
                // Stable, human message in every build; the raw error shows only
                // in debug so release users never see a raw SQLite string.
                Text("Your on-device log couldn't be opened. Reopen the app to try again.")
                #if DEBUG
                Text(message)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
                #endif
            }
        }
    }
}
