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
                Text("麻薯背单词")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text("背过的单词记得牢，有没有网都能学。")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: Spacing.sm) {
                AppleSignInButton(onSuccess: onFinished)
                GoogleSignInButton(onSuccess: onFinished)

                PrimaryButton("注册账号", systemImage: "envelope") {
                    route = .signUp
                }

                PrimaryButton("我已经有账号了", role: .secondary) {
                    route = .signIn
                }

                Button("不注册，直接使用") {
                    Task {
                        await auth.continueAsGuest()
                        onFinished()
                    }
                }
                .font(Typography.buttonLabel)
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: LayoutMetrics.minimumTapTarget)

                Text("游客模式的功能完全一样。学习进度保存在这台设备上，以后注册账号也不会丢。")
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
            "登录失败",
            isPresented: Binding(
                get: { auth.lastError != nil },
                set: { if !$0 { auth.clearError() } }
            )
        ) {
            Button("好") { auth.clearError() }
        } message: {
            Text(auth.lastError?.localizedDescription ?? "")
        }
    }
}

#Preview {
    AuthLandingView(onFinished: {})
}
