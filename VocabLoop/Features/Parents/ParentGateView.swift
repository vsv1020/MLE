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
                    Text("For grown-ups")
                        .font(Typography.sectionHeader)
                        .foregroundStyle(Palette.textPrimary)
                    Text("Answer this to see the weekly report.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                    Text(gate.question.prompt)
                        .font(Typography.statValueSmall)
                        .foregroundStyle(Palette.textPrimary)
                        .accessibilityLabel(gate.question.accessibilityPrompt)
                        .padding(.top, Spacing.xs)
                }
                .padding(.vertical, Spacing.xxs)

                TextField("Answer", text: $answer)
                    .keyboardType(.numberPad)
                    .focused($isFieldFocused)
                    .onSubmit(check)
                    .accessibilityLabel("Answer")

                Button("Check", action: check)
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                if showWrongHint {
                    Text("Not quite — here is a new one. \(RecapCopy.count(gate.attemptsLeft, "try", "tries")) left.")
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    // Only the report and the sharing switch sit behind this gate — the copy must
                    // not promise more.
                    Text("This keeps the weekly report and the sharing switch just for grown-ups.")
                }
            }
        }
        .navigationTitle("For parents")
        .onAppear { isFieldFocused = true }
    }

    /// "Sharing": whether the celebration screens offer a share card. The cards carry no name,
    /// email or anything typed, and go only where the share sheet sends them.
    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Sharing")
                .font(Typography.caption)
                .foregroundStyle(Palette.brandSecondary)
                .accessibilityAddTraits(.isHeader)
            Toggle("Allow sharing cards", isOn: $isSharingEnabled)
                .font(Typography.bodyEmphasis)
                .tint(Palette.brandPrimary)
            Text("Picture cards of goals, badges and words, with a link to VocabLoop. They never show a name or anything typed.")
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
            title: "Ask a grown-up",
            message: "This part of the app is for parents. Go back to try again later."
        )
        .frame(maxHeight: .infinity)
        .screenBackground()
        .navigationTitle("For parents")
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
