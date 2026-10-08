import SwiftUI
import UIKit

struct SignUpView: View {
    var onSuccess: () -> Void = {}

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                TextField("名字", text: $displayName)
                    .textContentType(.name)
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .email }

                TextField("邮箱", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
            } footer: {
                Text("目前的学习进度会保留下来。注册账号后进度归到账号里，不用从头开始。")
            }

            Section {
                SecureField("密码", text: $password)
                    // `.newPassword` opts into the keychain's strong-password suggestion.
                    .textContentType(.newPassword)
                    .focused($focus, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { focus = .confirm }

                SecureField("再输入一次密码", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .confirm)
                    .submitLabel(.go)
                    .onSubmit { submit() }

                if !password.isEmpty {
                    strengthMeter
                }
            } header: {
                Text("密码")
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    // States the actual rule. "Must contain a symbol" theatre teaches users
                    // to write "Password1!", which is worse than a long passphrase.
                    Text("至少 \(CredentialValidator.minimumPasswordLength) 个字符。长度比符号更重要，一句你记得住的短语就很安全。")
                    if let error = auth.lastError?.localizedDescription {
                        Text(error)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }

            Section {
                PrimaryButton(
                    "注册账号",
                    isLoading: auth.isBusy,
                    isEnabled: canSubmit
                ) {
                    submit()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("注册账号")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
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
                        .animation(Motion.value(reduceMotion), value: strength)
                }
            }
            .frame(height: 6)

            Text(strengthLabel(strength))
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("密码强度：\(strengthLabel(strength))")
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
        case ..<0.35: "弱"
        case ..<0.65: "一般"
        case ..<0.85: "强"
        default: "很强"
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
                    .font(Typography.heroGlyph)
                    .foregroundStyle(Palette.brandSecondary)
                Text("保存你的恢复码")
                    .font(Typography.screenTitle)
                    .multilineTextAlignment(.center)
                Text("你的账号保存在这台设备上，没办法通过邮件发送重置链接。如果忘了密码，这个恢复码是唯一能找回账号的方法。")
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
                .accessibilityLabel("恢复码：\(code.map(String.init).joined(separator: " "))")

            Button {
                UIPasteboard.general.string = code
                didCopy = true
            } label: {
                Label(didCopy ? "已复制" : "复制恢复码", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(Typography.caption)
            }
            .foregroundStyle(Palette.brandPrimary)

            Toggle("我已经把恢复码存在安全的地方了", isOn: $hasSaved)
                .font(Typography.body)

            PrimaryButton("继续", isEnabled: hasSaved, action: onAcknowledge)

            Text("随时可以在“设置 ▸ 账号”里生成新的恢复码。生成新码后，这个就失效了。")
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
