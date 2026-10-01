import SwiftUI

/// Settings ▸ For parents. Asks the gate question, then shows ``ParentReportView`` in place.
///
/// The gate lives in `@State`, so it is never persisted: leaving the screen and coming back asks
/// again, and three wrong answers lock it until then.
struct ParentGateView: View {
    @State private var gate = ParentGate()
    @State private var answer = ""
    @State private var showWrongHint = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        switch gate.state {
        case .passed:
            ParentReportView()
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
                    Text("This keeps the report, and anything that can be bought, away from small fingers.")
                }
            }
        }
        .navigationTitle("For parents")
        .onAppear { isFieldFocused = true }
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
