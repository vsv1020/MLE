import SwiftUI

struct SignInView: View {
    var onSuccess: () -> Void = {}

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isShowingReset = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case email, password }

    private var auth: AuthService { dependencies.auth }

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }

                SecureField("Password", text: $password)
                    // `.password`, not `.newPassword` — this tells the keychain to *offer*
                    // saved credentials rather than to suggest a new one.
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submit() }
            } footer: {
                if let error = auth.lastError?.localizedDescription {
                    Text(error)
                        .foregroundStyle(Palette.danger)
                }
            }

            Section {
                PrimaryButton(
                    "Sign in",
                    isLoading: auth.isBusy,
                    isEnabled: canSubmit
                ) {
                    submit()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Button("Forgot your password?") {
                    isShowingReset = true
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.brandPrimary)
            }

            Section {
                AppleSignInButton {
                    onSuccess()
                    dismiss()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Or")
            }
        }
        .navigationTitle("Sign in")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .sheet(isPresented: $isShowingReset) {
            NavigationStack {
                PasswordResetView(initialEmail: email)
            }
        }
        .onAppear { focus = .email }
        .onDisappear { auth.clearError() }
    }

    /// Only length is checked here, not shape. Rejecting an address at the keyboard is
    /// annoying and premature; the backend validates properly.
    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && !auth.isBusy
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            if await auth.signIn(email: email, password: password) {
                onSuccess()
                dismiss()
            }
        }
    }
}

#Preview {
    NavigationStack { SignInView() }
}
