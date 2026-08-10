import SwiftUI
import UIKit

struct SignUpView: View {
    var onSuccess: () -> Void = {}

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, email, password, confirm }

    private var auth: AuthService { dependencies.auth }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $displayName)
                    .textContentType(.name)
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .email }

                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
            } footer: {
                Text("Your progress so far is kept — creating an account claims it rather than starting over.")
            }

            Section {
                SecureField("Password", text: $password)
                    // `.newPassword` opts into the keychain's strong-password suggestion.
                    .textContentType(.newPassword)
                    .focused($focus, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { focus = .confirm }

                SecureField("Confirm password", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .confirm)
                    .submitLabel(.go)
                    .onSubmit { submit() }

                if !password.isEmpty {
                    strengthMeter
                }
            } header: {
                Text("Password")
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    // States the actual rule. "Must contain a symbol" theatre teaches users
                    // to write "Password1!", which is worse than a long passphrase.
                    Text("At least \(CredentialValidator.minimumPasswordLength) characters. Length matters more than symbols — a short phrase you can remember is strong.")
                    if let error = auth.lastError?.localizedDescription {
                        Text(error)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }

            Section {
                PrimaryButton(
                    "Create account",
                    isLoading: auth.isBusy,
                    isEnabled: canSubmit
                ) {
                    submit()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Create account")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        // The recovery code is the one thing in this flow the user cannot get back. It is
        // presented as a blocking sheet, not a toast, and cannot be swiped away.
        .sheet(
            isPresented: Binding(
                get: { auth.pendingRecoveryCode != nil },
                set: { if !$0 { auth.acknowledgeRecoveryCode() } }
            )
        ) {
            if let code = auth.pendingRecoveryCode {
                RecoveryCodeView(code: code) {
                    auth.acknowledgeRecoveryCode()
                    onSuccess()
                    dismiss()
                }
                .interactiveDismissDisabled()
            }
        }
        .onAppear { focus = .name }
        .onDisappear { auth.clearError() }
    }

    private var strengthMeter: some View {
        let strength = CredentialValidator.passwordStrength(password)
        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceRaised)
                    Capsule()
                        .fill(strengthColor(strength))
                        .frame(width: proxy.size.width * strength)
                        .animation(.easeOut(duration: 0.2), value: strength)
                }
            }
            .frame(height: 6)

            Text(strengthLabel(strength))
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(strengthLabel(strength))")
    }

    private func strengthColor(_ strength: Double) -> Color {
        switch strength {
        case ..<0.35: Palette.danger
        case ..<0.65: Palette.warning
        default: Palette.success
        }
    }

    private func strengthLabel(_ strength: Double) -> String {
        switch strength {
        case ..<0.35: "Weak"
        case ..<0.65: "Reasonable"
        case ..<0.85: "Strong"
        default: "Very strong"
        }
    }

    private var canSubmit: Bool {
        !email.isEmpty && password.count >= CredentialValidator.minimumPasswordLength
            && !confirmPassword.isEmpty && !auth.isBusy
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            await auth.signUp(
                email: email,
                password: password,
                confirmPassword: confirmPassword,
                displayName: displayName
            )
            // Success does not dismiss here — the recovery-code sheet does, once the user
            // has confirmed they saved it.
        }
    }
}

/// Shows the one-time recovery code, once.
///
/// The user must tick a confirmation before continuing. That is friction on purpose: this
/// code is the only way to recover an offline account, and a user who dismisses it without
/// reading has permanently lost their reset path.
struct RecoveryCodeView: View {
    let code: String
    let onAcknowledge: () -> Void

    @State private var hasSaved = false
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            VStack(spacing: Spacing.sm) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Palette.brandSecondary)
                Text("Save your recovery code")
                    .font(Typography.screenTitle)
                    .multilineTextAlignment(.center)
                Text("Your account lives on this device, so there is no email we can send a reset link to. This code is the only way back in if you forget your password.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Text(code)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
                .padding(Spacing.md)
                .frame(maxWidth: .infinity)
                .background(Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: Radius.nested, style: .continuous))
                .accessibilityLabel("Recovery code: \(code.map(String.init).joined(separator: " "))")

            Button {
                UIPasteboard.general.string = code
                didCopy = true
            } label: {
                Label(didCopy ? "Copied" : "Copy code", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(Typography.caption)
            }
            .foregroundStyle(Palette.brandPrimary)

            Toggle("I have saved this code somewhere safe", isOn: $hasSaved)
                .font(Typography.body)

            PrimaryButton("Continue", isEnabled: hasSaved, action: onAcknowledge)

            Text("You can generate a new code any time in Settings ▸ Account. Generating a new one replaces this one.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(Spacing.md)
        .readableWidth()
        .frame(maxHeight: .infinity)
        .screenBackground()
    }
}

#Preview("Sign up") {
    NavigationStack { SignUpView() }
}

#Preview("Recovery code") {
    RecoveryCodeView(code: "K7M2-9XPQ-4TVB-8HRN", onAcknowledge: {})
}
