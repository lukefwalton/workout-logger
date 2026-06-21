import SwiftUI

/// The app's home: the four surfaces from the screen map (§11), laid out as a
/// swipeable strip — drag horizontally between Today / History / Progress /
/// Settings, or tap the bar. Tab and swipe drive each other through one
/// `scrollPosition` binding.
///
/// Built on the native paging scroll (`scrollTargetBehavior(.paging)` +
/// `containerRelativeFrame`) rather than a hand-rolled gesture pager **on
/// purpose**: every screen is a vertical Form/List, so the hard part is
/// arbitrating the horizontal page-swipe against each screen's own vertical
/// scrolling. app-mobile solved that by hand (`shouldClaimHorizontalSwipe`); the
/// system gives us that arbitration for free and correctly. See
/// docs/learnings/004-swipe-navigation.md for what that trades away vs. matching
/// app-mobile's exact tuned feel.
///
/// All four surfaces are now real: Today logs, History audits/edits, Progress
/// charts deterministic aggregates, Settings manages the library and export.
///
/// NOTE: written correctly-by-inspection — the swipe *feel* needs an Xcode/device
/// pass (no simulator in this environment).
struct RootTabView: View {
    let store: WorkoutStore

    /// Owned by the app so a widget deep-link (`workoutchatlog://today`) can select a
    /// tab from outside the view.
    @Binding var tab: AppTab

    var body: some View {
        pager
            .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
    }

    private var pager: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(AppTab.allCases) { destination in
                        page(for: destination)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .id(destination)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding<AppTab?>(get: { tab }, set: { tab = $0 ?? tab }))
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func page(for destination: AppTab) -> some View {
        switch destination {
        case .today: TodayView(store: store)
        case .history: HistoryView(store: store, appTab: $tab)
        case .progress: ProgressTabView(store: store, appTab: $tab)
        case .settings: SettingsView(store: store, appTab: $tab)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { destination in
                Button {
                    withAnimation(.snappy) { tab = destination }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: destination.icon)
                            .font(.system(size: 18, weight: .semibold))
                        Text(destination.title)
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(destination == tab ? Color.white : Theme.steel.opacity(0.75))
                    .background {
                        if destination == tab {
                            Capsule()
                                .fill(Theme.ocean.gradient)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(destination.title)
                .accessibilityAddTraits(destination == tab ? .isSelected : [])
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.65), lineWidth: 1)
        }
        .shadow(color: Theme.deepSea.opacity(0.12), radius: 18, y: 8)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }
}

/// The home destinations, in swipe order. Top-level (not nested in the view) so
/// the ordering — which is also the left-to-right page order — is unit-testable.
enum AppTab: Int, CaseIterable, Identifiable {
    case today, history, progress, settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .history: "History"
        case .progress: "Progress"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .today: "square.and.pencil"
        case .history: "clock"
        case .progress: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape"
        }
    }
}
