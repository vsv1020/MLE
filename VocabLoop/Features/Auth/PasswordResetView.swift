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
        .navigationTitle("Reset password")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(didReset ? "Done" : "Cancel") { dismiss() }
            }
        }
        .onDisappear { auth.clearError() }
    }

    private var emailSection: some View {
        Group {
            Section {
                TextField("Email", text: $email)
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
                PrimaryButton("Continue", isLoading: auth.isBusy, isEnabled: !email.isEmpty) {
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
                Text(challenge == .recoveryCode ? "Recovery code" : "Reset code")
            } footer: {
                Text(
                    challenge == .recoveryCode
                        ? "The 16-character code shown when you created your account. Dashes and letter case do not matter."
                        : "Check your email for the code we just sent."
                )
            }

            Section {
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmPassword)
                    .textContentType(.newPassword)
            } header: {
                Text("New password")
            } footer: {
                if let error = auth.lastError?.localizedDescription {
                    Text(error).foregroundStyle(Palette.danger)
                }
            }

            Section {
                PrimaryButton(
                    "Reset password",
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
                Text("Password changed")
                    .font(Typography.sectionHeader)
                Text("Sign in with your new password. Your recovery code has been used up — generate a new one in Settings ▸ Account.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
        }
    }

    private func proofFieldLabel(_ challenge: PasswordResetChallenge) -> String {
        challenge == .recoveryCode ? "XXXX-XXXX-XXXX-XXXX" : "Code from email"
    }
}

#Preview {
    NavigationStack { PasswordResetView(initialEmail: "you@example.com") }
}
