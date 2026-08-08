import SwiftUI

/// Settings ▸ Account.
///
/// Everything an account needs to be complete rather than merely present: profile editing,
/// password change, recovery-code regeneration, data export, sign out, and deletion.
///
/// Account deletion is in-app and reachable in two taps, because App Store guideline
/// 5.1.1(v) requires it and because burying it is hostile.
struct AccountView: View {
    @Environment(\.appDependencies) private var dependencies

    @State private var isShowingSignIn = false
    @State private var isShowingSignUp = false
    @State private var isShowingChangePassword = false
    @State private var isShowingDeleteConfirmation = false
    @State private var isEditingProfile = false
    @State private var draftName = ""
    /// Wrapped because `sheet(item:)` needs `Identifiable`, and `String`/`URL` are not.
    @State private var newRecoveryCode: IdentifiableValue<String>?
    @State private var exportURL: IdentifiableValue<URL>?
    @State private var exportError: String?
    @State private var profileError: String?

    private var auth: AuthService { dependencies.auth }
    private var session: Session? { auth.current }

    var body: some View {
        Form {
            identitySection

            if auth.isGuest {
                guestSection
            } else {
                profileSection
                securitySection
            }

            dataSection

            if !auth.isGuest {
                dangerSection
            }
        }
        .navigationTitle("Account")
        .sheet(isPresented: $isShowingSignIn) {
            NavigationStack { SignInView() }
        }
        .sheet(isPresented: $isShowingSignUp) {
            NavigationStack { SignUpView() }
        }
        .sheet(isPresented: $isShowingChangePassword) {
            NavigationStack { ChangePasswordView() }
        }
        .sheet(item: $newRecoveryCode) { wrapper in
            RecoveryCodeView(code: wrapper.value) { newRecoveryCode = nil }
        }
        .sheet(item: $exportURL) { wrapper in
            ShareLink(item: wrapper.value) {
                Label("Share export", systemImage: "square.and.arrow.up")
            }
            .padding(Spacing.lg)
            .presentationDetents([.height(160)])
        }
        .alert("Delete your account?", isPresented: $isShowingDeleteConfirmation) {
            Button("Delete everything", role: .destructive) {
                Task { await auth.deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Spell out exactly what goes. "This cannot be undone" without a list is how
            // users end up surprised.
            Text("This permanently removes your account, every card you are studying, your full review history and your streak. The dictionary itself stays. This cannot be undone.")
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert("Could not save your name", isPresented: Binding(
            get: { profileError != nil },
            set: { if !$0 { profileError = nil } }
        )) {
            Button("OK") { profileError = nil }
        } message: {
            Text(profileError ?? "")
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            HStack(spacing: Spacing.md) {
                Text(dependencies.account?.initials ?? "?")
                    .font(Typography.statValueSmall)
                    .foregroundStyle(Palette.onBrand)
                    .frame(width: 52, height: 52)
                    .background(Palette.brandPrimary)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(session?.displayName ?? "Guest")
                        .font(Typography.bodyEmphasis)
                    if let email = session?.email {
                        Text(email)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if let provider = session?.provider {
                        Chip(
                            provider == .guest ? "No account" : "Signed in with \(provider.displayName)",
                            color: provider == .guest ? Palette.textSecondary : Palette.brandSecondary
                        )
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.vertical, Spacing.xxs)
            .accessibilityElement(children: .combine)
        }
    }

    private var guestSection: some View {
        Section {
            AppleSignInButton()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            Button("Create an account") { isShowingSignUp = true }
            Button("Sign in") { isShowingSignIn = true }
        } header: {
            Text("Sync across devices")
        } footer: {
            Text("You are studying as a guest, and everything works. An account lets you keep your progress if you change device — and creating one keeps what you have already learned.")
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            if isEditingProfile {
                TextField("Name", text: $draftName)
                    .textContentType(.name)
                HStack {
                    Button("Cancel") { isEditingProfile = false }
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button("Save") {
                        Task {
                            // Only close the editor when the save actually landed. Closing
                            // regardless discards what the user typed while looking like it
                            // worked — the failure is silent and the old name reappears.
                            if await auth.updateProfile(displayName: draftName, email: nil) {
                                isEditingProfile = false
                            } else {
                                profileError = auth.lastError?.localizedDescription
                                    ?? "Your name could not be saved."
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("Edit name") {
                    draftName = session?.displayName ?? ""
                    isEditingProfile = true
                }
            }
        }
    }

    private var securitySection: some View {
        Section {
            if auth.canChangePassword {
                Button("Change password") { isShowingChangePassword = true }
            }
            if session?.provider == .local {
                Button("Generate a new recovery code") {
                    Task {
                        if let code = await auth.regenerateRecoveryCode() {
                            newRecoveryCode = IdentifiableValue(value: code)
                        }
                    }
                }
            }
            Button("Sign out") {
                Task { await auth.signOut() }
            }
            .foregroundStyle(Palette.brandPrimary)
        } header: {
            Text("Security")
        } footer: {
            if session?.provider == .apple {
                Text("This account signs in with Apple, so Apple manages the password.")
            } else if session?.provider == .local {
                Text("Signing out leaves your study data on this device. Signing back in restores it.")
            }
        }
    }

    private var dataSection: some View {
        Section {
            Button("Export my data") {
                export()
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("A JSON file containing every word you are studying and your complete review history — the same data a future weight optimiser would use.")
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Delete account", role: .destructive) {
                isShowingDeleteConfirmation = true
            }
        }
    }

    private func export() {
        do {
            exportURL = IdentifiableValue(
                value: try DataExporter(context: dependencies.context).exportJSON()
            )
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// Wraps a value so it can drive `sheet(item:)`.
///
/// `String` and `URL` are not `Identifiable`, and retrofitting a conformance onto a stdlib
/// type would leak into every file in the module.
struct IdentifiableValue<Value>: Identifiable {
    let value: Value
    let id = UUID()
}

#Preview {
    NavigationStack { AccountView() }
}
