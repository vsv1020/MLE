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
            Section("当前密码") {
                SecureField("当前密码", text: $currentPassword)
                    .textContentType(.password)
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
                } else {
                    Text("至少 \(CredentialValidator.minimumPasswordLength) 个字符。")
                }
            }

            Section {
                PrimaryButton(
                    "修改密码",
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
        .navigationTitle("修改密码")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
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
