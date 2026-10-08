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
        .navigationTitle("账号")
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
                Label("分享导出文件", systemImage: "square.and.arrow.up")
            }
            .padding(Spacing.lg)
            .presentationDetents([.height(160)])
        }
        .alert("删除你的账号？", isPresented: $isShowingDeleteConfirmation) {
            Button("全部删除", role: .destructive) {
                Task { await auth.deleteAccount() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            // Spell out exactly what goes. "This cannot be undone" without a list is how
            // users end up surprised.
            Text("这会永久删除你的账号、正在学的所有卡片、全部复习记录和连续打卡。词典本身会保留。删除后无法恢复。")
        }
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        // Apple and Google report failures through `lastError` with no form of their own to
        // show it on. The sign-in and sign-up sheets display theirs, so this stays out of the
        // way while either is open.
        .alert("登录失败", isPresented: Binding(
            get: { auth.isGuest && auth.lastError != nil && !isShowingSignIn && !isShowingSignUp },
            set: { if !$0 { auth.clearError() } }
        )) {
            Button("好") { auth.clearError() }
        } message: {
            Text(auth.lastError?.localizedDescription ?? "")
        }
        .alert("名字没能保存", isPresented: Binding(
            get: { profileError != nil },
            set: { if !$0 { profileError = nil } }
        )) {
            Button("好") { profileError = nil }
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
                    Text(session?.displayName ?? "游客")
                        .font(Typography.bodyEmphasis)
                    if let email = session?.email {
                        Text(email)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if let provider = session?.provider {
                        Chip(
                            provider == .guest ? "未注册账号" : "已通过 \(provider.displayName) 登录",
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
            if GoogleSignInConfiguration.isConfigured {
                GoogleSignInButton()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Button("注册账号") { isShowingSignUp = true }
            Button("登录") { isShowingSignIn = true }
        } header: {
            Text("多设备同步")
        } footer: {
            Text("你现在以游客身份学习，所有功能都能用。有了账号，换设备也能保留进度；注册时，已经学过的内容也会保留。")
        }
    }

    private var profileSection: some View {
        Section("个人资料") {
            if isEditingProfile {
                TextField("名字", text: $draftName)
                    .textContentType(.name)
                HStack {
                    Button("取消") { isEditingProfile = false }
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button("保存") {
                        Task {
                            // Only close the editor when the save actually landed. Closing
                            // regardless discards what the user typed while looking like it
                            // worked — the failure is silent and the old name reappears.
                            if await auth.updateProfile(displayName: draftName, email: nil) {
                                isEditingProfile = false
                            } else {
                                profileError = auth.lastError?.localizedDescription
                                    ?? "名字没能保存。"
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("修改名字") {
                    draftName = session?.displayName ?? ""
                    isEditingProfile = true
                }
            }
        }
    }

    private var securitySection: some View {
        Section {
            if auth.canChangePassword {
                Button("修改密码") { isShowingChangePassword = true }
            }
            if session?.provider == .local {
                Button("生成新的恢复码") {
                    Task {
                        if let code = await auth.regenerateRecoveryCode() {
                            newRecoveryCode = IdentifiableValue(value: code)
                        }
                    }
                }
            }
            Button("退出登录") {
                Task { await auth.signOut() }
            }
            .foregroundStyle(Palette.brandPrimary)
        } header: {
            Text("安全")
        } footer: {
            if session?.provider == .apple {
                Text("这个账号通过 Apple 登录，密码由 Apple 管理。")
            } else if session?.provider == .local {
                Text("退出登录后，学习数据仍留在这台设备上。重新登录就能恢复。")
            }
        }
    }

    private var dataSection: some View {
        Section {
            Button("导出我的数据") {
                export()
            }
        } header: {
            Text("你的数据")
        } footer: {
            Text("一个 JSON 文件，包含你正在学的所有单词和完整的复习记录，也就是以后优化记忆参数要用的数据。")
        }
    }

    private var dangerSection: some View {
        Section {
            Button("删除账号", role: .destructive) {
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
