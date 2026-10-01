import SwiftUI
import SwiftData

@main
struct VocabLoopApp: App {
    @State private var dependencies: AppDependencies
    /// `nil` unless the store could not be opened at all — see ``LaunchFailureView``.
    private let launchFailure: String?

    init() {
        Self.resetFirstRunStateIfUITesting()

        // The container is the one thing that must exist before anything else can. If it
        // genuinely cannot be created — after PersistenceController has already tried
        // quarantining a corrupt store — the app shows an explanation rather than crashing
        // on a force-unwrap in front of the user.
        do {
            // `sharedContainer` rather than `makeContainer`: an App Intent may have already
            // opened it by launching the app in the background, and two containers on one
            // store file in one process is not a supported configuration.
            //
            // Both this and `AppDependencies.init` are main-actor isolated, which is fine —
            // SwiftUI's `App` is itself `@MainActor`, so this initialiser already is.
            let container = try PersistenceController.sharedContainer()
            _dependencies = State(initialValue: AppDependencies(container: container))
            launchFailure = nil
        } catch {
            _dependencies = State(initialValue: AppDependencies.preview())
            launchFailure = error.localizedDescription
        }
    }

    /// Put the first-run flags back to their unset state when the UI suite asks for it.
    ///
    /// The UI tests used to pass `-onboarding.completed NO` as a launch argument, which does not
    /// work: launch arguments land in `NSArgumentDomain`, which sits *above* the application
    /// domain and is read-only. `@AppStorage` therefore kept reading `false` no matter what the
    /// app wrote, so `RootView.advance()` sent the user back to onboarding forever and the tab bar
    /// was never reachable. Every UI test failed on a missing tab bar.
    ///
    /// A flag the app acts on, rather than a value the app is forced to read, means the reset is a
    /// real write to the domain `@AppStorage` owns — so finishing onboarding sticks.
    private static func resetFirstRunStateIfUITesting() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-uiTestingResetFirstRun") else { return }
        for key in ["onboarding.completed", "auth.landingShown"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        #endif
    }

    /// `vocabloop://mochi` opens Mochi's room; `vocabloop://study` — and any other path, so a
    /// link from a newer widget never does nothing — shows the card.
    static func action(for url: URL) -> IntentLaunchRequest.Action? {
        guard url.scheme?.lowercased() == "vocabloop" else { return nil }
        switch url.host()?.lowercased() {
        case "mochi": return .showMochi
        default: return .startReview
        }
    }

    var body: some Scene {
        WindowGroup {
            if let launchFailure {
                LaunchFailureView(message: launchFailure)
            } else {
                RootView()
                    .environment(\.appDependencies, dependencies)
                    .modelContainer(dependencies.container)
                    .tint(Palette.brandPrimary)
                    // Widget and Live Activity taps. Left as a note for the root session, exactly
                    // like an App Intent, so a cold launch and a warm one take the same path.
                    .onOpenURL { url in
                        IntentLaunchRequest.shared.pendingAction = Self.action(for: url)
                    }
            }
        }
    }
}

/// Shown only when the persistent store cannot be opened even after quarantining.
///
/// Rare enough that a polished screen would be waste, serious enough that a crash would be
/// the wrong answer — the user needs to know it is not their fault and what to try.
struct LaunchFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(Typography.heroGlyph)
                .foregroundStyle(Palette.warning)
            Text("VocabLoop could not open its library")
                .font(Typography.screenTitle)
                .multilineTextAlignment(.center)
            Text("Reinstalling the app will fix this, but will remove study progress that has not been synced.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, Spacing.xs)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }
}
