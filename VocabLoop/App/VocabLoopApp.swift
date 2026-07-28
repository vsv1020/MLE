import SwiftUI
import SwiftData

@main
struct VocabLoopApp: App {
    @State private var dependencies: AppDependencies
    /// `nil` unless the store could not be opened at all — see ``LaunchFailureView``.
    private let launchFailure: String?

    init() {
        // The container is the one thing that must exist before anything else can. If it
        // genuinely cannot be created — after PersistenceController has already tried
        // quarantining a corrupt store — the app shows an explanation rather than crashing
        // on a force-unwrap in front of the user.
        do {
            let container = try PersistenceController.makeContainer()
            _dependencies = State(initialValue: AppDependencies(container: container))
            launchFailure = nil
        } catch {
            _dependencies = State(initialValue: AppDependencies.preview())
            launchFailure = error.localizedDescription
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
                .font(.system(size: 44))
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
