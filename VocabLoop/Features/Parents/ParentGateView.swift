import SwiftUI

/// Settings ▸ For parents. Asks the gate question, then shows ``ParentReportView`` in place,
/// with the "Sharing" switch beneath it (sharing plan §4).
///
/// The gate lives in `@State`, so it is never persisted: leaving the screen and coming back asks
/// again, and three wrong answers lock it until then.
struct ParentGateView: View {
    @State private var gate = ParentGate()
    @State private var answer = ""
    @State private var showWrongHint = false
    @FocusState private var isFieldFocused: Bool
    /// Device-level, default on. Off hides every share button in the app, the weekly recap's too.
    @AppStorage(ShareSettings.enabledKey) private var isSharingEnabled = true

    var body: some View {
        switch gate.state {
        case .passed:
            ParentReportView()
                .safeAreaInset(edge: .bottom, spacing: 0) { sharingSection }
        case .asking:
            asking
        case .locked:
            locked
        }
    }

    private var asking: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("大人专区")
                        .font(Typography.sectionHeader)
                        .foregroundStyle(Palette.textPrimary)
                    Text("答对这道题就能查看每周报告。")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                    Text(gate.question.prompt)
                        .font(Typography.statValueSmall)
                        .foregroundStyle(Palette.textPrimary)
                        .accessibilityLabel(gate.question.accessibilityPrompt)
                        .padding(.top, Spacing.xs)
                }
                .padding(.vertical, Spacing.xxs)

                TextField("答案", text: $answer)
                    .keyboardType(.numberPad)
                    .focused($isFieldFocused)
                    .onSubmit(check)
                    .accessibilityLabel("答案")

                Button("确定", action: check)
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                if showWrongHint {
                    Text("不太对，换一道题。还剩 \(RecapCopy.count(gate.attemptsLeft, "次机会"))。")
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    // Only the report and the sharing switch sit behind this gate — the copy must
                    // not promise more.
                    Text("这样每周报告和分享开关就只有大人能打开。")
                }
            }
        }
        .navigationTitle("给家长")
        .onAppear { isFieldFocused = true }
    }

    /// "Sharing": whether the celebration screens offer a share card. The cards carry no name,
    /// email or anything typed, and go only where the share sheet sends them.
    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("分享")
                .font(Typography.caption)
                .foregroundStyle(Palette.brandSecondary)
                .accessibilityAddTraits(.isHeader)
            Toggle("允许分享卡片", isOn: $isSharingEnabled)
                .font(Typography.bodyEmphasis)
                .tint(Palette.brandPrimary)
            Text("分享目标、徽章和单词的图片卡片，附带麻薯背单词的链接。卡片上从不显示名字或任何输入过的内容。")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .drawnPanel(seed: 0x5A4E_0001, cornerRadius: Radius.card)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .readableWidth()
        .frame(maxWidth: .infinity)
        .background(Palette.canvas.opacity(0.96).ignoresSafeArea(edges: .bottom))
    }

    private var locked: some View {
        EmptyStateView(
            systemImage: "lock.fill",
            title: "请找大人帮忙",
            message: "这里是给家长用的。返回后稍后再试。"
        )
        .frame(maxHeight: .infinity)
        .screenBackground()
        .navigationTitle("给家长")
    }

    private func check() {
        // Blank costs nothing — the gate ignores it, and so does the hint.
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let result = gate.submit(answer)
        answer = ""
        switch result {
        case .asking:
            showWrongHint = true
        case .passed, .locked:
            showWrongHint = false
            isFieldFocused = false
        }
    }
}

#Preview {
    NavigationStack { ParentGateView() }
}
