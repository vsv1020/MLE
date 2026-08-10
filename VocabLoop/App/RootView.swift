import SwiftUI
import SwiftData

/// Decides what the user sees first: onboarding, the auth landing, or the app.
///
/// Note what is *not* here: a sign-in wall. Auth is offered once and can be skipped
/// forever — ``AuthService`` always has a session, so the tabs are reachable from the
/// first launch.
struct RootView: View {
    @Environment(\.appDependencies) private var dependencies

    /// Onboarding completion is device-local UI state, not user data, so `UserDefaults` is
    /// the right home for it — it should not sync to a second device that has its own
    /// first-run experience.
    @AppStorage("onboarding.completed") private var hasCompletedOnboarding = false
    @AppStorage("auth.landingShown") private var hasSeenAuthLanding = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: Phase = .launching

    private enum Phase {
        case launching
        case onboarding
        case authLanding
        case main
    }

    var body: some View {
        Group {
            switch phase {
            case .launching:
                LaunchView()
            case .onboarding:
                OnboardingView {
                    hasCompletedOnboarding = true
                    advance()
                }
            case .authLanding:
                AuthLandingView(
                    onFinished: {
                        hasSeenAuthLanding = true
                        advance()
                    }
                )
            case .main:
                MainTabView()
            }
        }
        .animation(Motion.phase(reduceMotion), value: phase)
        .task {
            await dependencies.bootstrap()
            advance()
        }
    }

    private func advance() {
        if !hasCompletedOnboarding {
            phase = .onboarding
        } else if !hasSeenAuthLanding, dependencies.auth.isGuest {
            phase = .authLanding
        } else {
            phase = .main
        }
    }
}

/// Bridging state while the store opens and content imports.
///
/// Deliberately quiet: on a warm launch it is on screen for a few frames, and anything
/// more animated would flash.
struct LaunchView: View {
    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 52))
                .foregroundStyle(Palette.brandPrimary)
            Text("VocabLoop")
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.textPrimary)
            ProgressView()
                .tint(Palette.brandPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .accessibilityLabel("Loading VocabLoop")
    }
}
