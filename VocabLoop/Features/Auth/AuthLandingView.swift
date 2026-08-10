import SwiftUI

/// Offers an account, and offers *not* having one with equal weight.
///
/// "Continue without an account" is a full-width button in the same visual language as the
/// others, not grey small print in a corner. Guest is a supported way to use the app, and
/// dressing it up as a downgrade would be a dark pattern.
struct AuthLandingView: View {
    let onFinished: () -> Void

    @Environment(\.appDependencies) private var dependencies
    @State private var route: Route?

    private enum Route: Hashable, Identifiable {
        case signIn, signUp
        var id: Self { self }
    }

    private var auth: AuthService { dependencies.auth }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            VStack(spacing: Spacing.sm) {
                Image(systemName: "text.book.closed.fill")
                    .font(Typography.heroGlyph)
                    .foregroundStyle(Palette.brandPrimary)
                Text("VocabLoop")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Vocabulary that sticks, with or without a signal.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: Spacing.sm) {
                AppleSignInButton(onSuccess: onFinished)

                PrimaryButton("Create an account", systemImage: "envelope") {
                    route = .signUp
                }

                PrimaryButton("I already have an account", role: .secondary) {
                    route = .signIn
                }

                Button("Continue without an account") {
                    Task {
                        await auth.continueAsGuest()
                        onFinished()
                    }
                }
                .font(Typography.buttonLabel)
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: LayoutMetrics.minimumTapTarget)

                Text("Guest mode is fully functional. Your progress is saved on this device, and you can create an account later without losing it.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.sm)
            }
        }
        .padding(Spacing.md)
        .readableWidth()
        .screenBackground()
        .sheet(item: $route) { destination in
            NavigationStack {
                switch destination {
                case .signIn:
                    SignInView(onSuccess: onFinished)
                case .signUp:
                    SignUpView(onSuccess: onFinished)
                }
            }
        }
        .alert(
            "Sign in failed",
            isPresented: Binding(
                get: { auth.lastError != nil },
                set: { if !$0 { auth.clearError() } }
            )
        ) {
            Button("OK") { auth.clearError() }
        } message: {
            Text(auth.lastError?.localizedDescription ?? "")
        }
    }
}

#Preview {
    AuthLandingView(onFinished: {})
}
