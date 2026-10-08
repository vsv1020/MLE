import SwiftUI

/// Password reset, in two stages.
///
/// The first stage never says whether the address exists — doing so would turn this form
/// into an account-enumeration oracle. It always advances to the challenge stage, and the
/// challenge itself is where a wrong address fails.
struct PasswordResetView: View {
    let initialEmail: String

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var email: String
    @State private var challenge: PasswordResetChallenge?
    @State private var proof = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var didReset = false

    private var auth: AuthService { dependencies.auth }

    init(initialEmail: String = "") {
        self.initialEmail = initialEmail
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        Form {
            if didReset {
                successSection
            } else if let challenge {
                challengeSection(challenge)
            } else {
                emailSection
            }
        }
        .navigationTitle("重置密码")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(didReset ? "完成" : "取消") { dismiss() }
            }
        }
        .onDisappear { auth.clearError() }
    }

    private var emailSection: some View {
        Group {
            Section {
                TextField("邮箱", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                if let error = auth.lastError?.localizedDescription {
                    Text(error).foregroundStyle(Palette.danger)
                }
            }

            Section {
                PrimaryButton("继续", isLoading: auth.isBusy, isEnabled: !email.isEmpty) {
                    Task { challenge = await auth.beginPasswordReset(email: email) }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private func challengeSection(_ challenge: PasswordResetChallenge) -> some View {
        Group {
            Section {
                TextField(proofFieldLabel(challenge), text: $proof)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(challenge == .recoveryCode ? .system(.body, design: .monospaced) : .body)
            } header: {
                Text(challenge == .recoveryCode ? "恢复码" : "重置码")
            } footer: {
                Text(
                    challenge == .recoveryCode
                        ? "注册账号时显示的 16 位恢复码。横线和大小写都没关系。"
                        : "去邮箱查看我们刚刚发送的重置码。"
                )
            }

            Section {
                SecureField("新密码", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("再输入一次新密码", text: $confirmPassword)
                    .textContentType(.newPassword)
            } header: {
                Text("新密码")
            } footer: {
                if let error = auth.lastError?.localizedDescription {
                    Text(error).foregroundStyle(Palette.danger)
                }
            }

            Section {
                PrimaryButton(
                    "重置密码",
                    isLoading: auth.isBusy,
                    isEnabled: !proof.isEmpty && newPassword.count >= CredentialValidator.minimumPasswordLength
                ) {
                    Task {
                        didReset = await auth.completePasswordReset(
                            email: email, proof: proof,
                            newPassword: newPassword, confirmPassword: confirmPassword
                        )
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private var successSection: some View {
        Section {
            VStack(spacing: Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(Typography.heroGlyph)
                    .foregroundStyle(Palette.success)
                Text("密码已修改")
                    .font(Typography.sectionHeader)
                Text("请用新密码登录。原来的恢复码已经用掉了，请到“设置 ▸ 账号”里生成新的。")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
        }
    }

    private func proofFieldLabel(_ challenge: PasswordResetChallenge) -> String {
        challenge == .recoveryCode ? "XXXX-XXXX-XXXX-XXXX" : "邮件里的重置码"
    }
}

#Preview {
    NavigationStack { PasswordResetView(initialEmail: "you@example.com") }
}
