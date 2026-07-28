import SwiftUI

struct ChangePasswordView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    private var auth: AuthService { dependencies.auth }

    var body: some View {
        Form {
            Section("Current password") {
                SecureField("Current password", text: $currentPassword)
                    .textContentType(.password)
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
                } else {
                    Text("At least \(CredentialValidator.minimumPasswordLength) characters.")
                }
            }

            Section {
                PrimaryButton(
                    "Change password",
                    isLoading: auth.isBusy,
                    isEnabled: canSubmit
                ) {
                    Task {
                        if await auth.changePassword(
                            current: currentPassword, new: newPassword, confirm: confirmPassword
                        ) {
                            dismiss()
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Change password")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onDisappear { auth.clearError() }
    }

    private var canSubmit: Bool {
        !currentPassword.isEmpty
            && newPassword.count >= CredentialValidator.minimumPasswordLength
            && !auth.isBusy
    }
}

#Preview {
    NavigationStack { ChangePasswordView() }
}
