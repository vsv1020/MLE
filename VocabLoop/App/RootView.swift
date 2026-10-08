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
                // The card *is* the app.
                //
                // This used to be `MainTabView`, so opening the app landed you on a dashboard
                // with a button that started studying. Counting from the icon, a first launch
                // put seven screens between the user and their first word, four of which were
                // questions. Now there are none: the session builds itself and everything else
                // — browse, decks, progress, settings — sits behind the library button in its
                // top bar.
                StudySessionView(options: rootOptions, presentation: .root)
            }
        }
        .animation(Motion.phase(reduceMotion), value: phase)
        .task {
            await dependencies.bootstrap()
            advance()
        }
    }

    /// Session options for the root session.
    ///
    /// Deliberately the plain defaults rather than anything read from preferences: the root
    /// session studies everything, in every enrolled language, and the caps are batch sizes the
    /// queue tops up from. Narrowing by deck or language is what starting a session *from* a
    /// deck is for.
    private var rootOptions: ReviewQueueBuilder.Options {
        ReviewQueueBuilder.Options()
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
            // The first thing anyone sees is the character, not a book glyph. Static here in
            // practice — on a warm launch this screen lasts a few frames — but the breathing is
            // harmless if the store takes longer to open.
            Mascot(mood: .happy)
                .frame(width: 96, height: 80)
            Text("麻薯背单词")
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.textPrimary)
            ProgressView()
                .tint(Palette.brandPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .accessibilityLabel("麻薯背单词加载中")
    }
}
