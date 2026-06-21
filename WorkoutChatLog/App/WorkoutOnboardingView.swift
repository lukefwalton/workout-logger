import SwiftUI
import LFWDesignSystem

/// First-run walkthrough. Built from the shared `LFWDesignSystem` onboarding
/// kit so this app's welcome flow feels native to the family — same hero
/// scaffold, same gradient background, same CTA pill, same page dots — and
/// any chrome tweaks propagate to siblings automatically.
struct WorkoutOnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0

    private let pageCount = 4

    var body: some View {
        ZStack {
            LFWOnboardingBackground()

            TabView(selection: $page) {
                WorkoutWelcomeScreen(action: advance)
                    .tag(0)

                WorkoutPromiseScreen(
                    symbol: "lock.fill",
                    eyebrow: "Local first",
                    title: "Your training log\nstays on this phone.",
                    message: "No account, no server, no tracking. The database opens locally and writes locally.",
                    action: advance
                )
                .tag(1)

                WorkoutPromiseScreen(
                    symbol: "checkmark.seal.fill",
                    eyebrow: "You decide",
                    title: "The parser proposes.\nYou confirm.",
                    message: "Shorthand like bench 135x8 becomes a draft. Nothing is saved until you approve it.",
                    action: advance
                )
                .tag(2)

                WorkoutReadyScreen(onFinish: onFinish)
                    .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack {
                LFWPageDots(count: pageCount, index: page)
                    .padding(.top, 10)
                Spacer()
            }
            .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
    }

    private func advance() {
        withAnimation(.easeInOut) { page = min(page + 1, pageCount - 1) }
    }
}

// MARK: - Screens

private struct WorkoutWelcomeScreen: View {
    let action: () -> Void

    var body: some View {
        LFWOnboardingScaffold(
            symbol: "figure.strengthtraining.traditional",
            eyebrow: "Private Workout Logger",
            title: "Log fast.\nKeep control."
        ) {
            LFWOnboardingMessage("Type the set the way you would text it. Clean it up only when it matters.")
        } footer: {
            Button("Get started", action: action)
                .buttonStyle(.lfwCTA)
        }
    }
}

private struct WorkoutPromiseScreen: View {
    let symbol: String
    let eyebrow: String
    let title: String
    let message: String
    let action: () -> Void

    var body: some View {
        LFWOnboardingScaffold(symbol: symbol, eyebrow: eyebrow, title: title) {
            LFWOnboardingMessage(message)
        } footer: {
            Button("Continue", action: action)
                .buttonStyle(.lfwCTA)
        }
    }
}

private struct WorkoutReadyScreen: View {
    let onFinish: () -> Void

    var body: some View {
        LFWOnboardingScaffold(
            symbol: "sparkles",
            eyebrow: "First rep",
            title: "Try a quick set."
        ) {
            VStack(spacing: 12) {
                LFWFeatureRow(symbol: "text.cursor", text: "Start with `bench 135x8`, `3x10 @ 135`, or `bw x12`.")
                LFWFeatureRow(symbol: "pencil.and.list.clipboard", text: "Review the parsed sets before they hit the log.")
                LFWFeatureRow(symbol: "chart.line.uptrend.xyaxis", text: "History and progress charts will build from confirmed data.")
            }
            .padding(.top, 10)
        } footer: {
            Button("Start Logging", action: onFinish)
                .buttonStyle(.lfwCTA)
        }
    }
}
