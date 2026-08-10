import SwiftUI
import UIKit

/// Settings ▸ Memory algorithm ▸ Tune to my memory.
///
/// FSRS weights are meant to be fitted to the individual learner. Fitting them needs an
/// optimiser, which is not built in yet — so this screen does the honest version: it says
/// exactly how much history exists, whether that is enough, and lets a user who wants to fit
/// their own weights today export the log and paste the result back.
///
/// The alternative would be to hide the whole idea until the optimiser ships. That would waste
/// the review history already being collected, and the readiness figure is genuinely useful on
/// its own — it tells the user their data is going somewhere.
struct OptimizerSettingsView: View {
    @Environment(\.appDependencies) private var dependencies

    @State private var readiness: OptimizerReadiness?
    @State private var exportURL: IdentifiableValue<URL>?
    @State private var pastedWeights = ""
    @State private var isPasting = false
    @State private var message: String?
    @State private var errorMessage: String?

    private var service: OptimizerService { OptimizerService(context: dependencies.context) }

    var body: some View {
        Form {
            readinessSection
            exportSection
            applySection
            if dependencies.preferences?.fsrsWeights != nil {
                resetSection
            }
            explanationSection
        }
        .navigationTitle("Tune to my memory")
        .task { refresh() }
        .sheet(item: $exportURL) { wrapper in
            ShareLink(item: wrapper.value) {
                Label("Share review history", systemImage: "square.and.arrow.up")
            }
            .padding(Spacing.lg)
            .presentationDetents([.height(160)])
        }
        .alert("Could not do that", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var readinessSection: some View {
        Section {
            if let readiness {
                LabeledContent("Reviews recorded", value: "\(readiness.reviewCount)")
                LabeledContent("Cards covered", value: "\(readiness.cardCount)")
                LabeledContent(
                    "Currently using",
                    value: readiness.hasFittedWeights ? "Your fitted weights" : "Published defaults"
                )

                // A progress bar toward the recommended volume, so the number means something.
                if !readiness.meetsRecommended {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        ProgressView(
                            value: Double(readiness.reviewCount),
                            total: Double(OptimizerReadiness.recommendedReviews)
                        )
                        .tint(Palette.brandPrimary)
                        Text(readiness.explanation)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.vertical, Spacing.xxs)
                } else {
                    Text(readiness.explanation)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Your history")
        }
    }

    private var exportSection: some View {
        Section {
            Button("Export my review history") {
                guard let preferences = dependencies.preferences else { return }
                do {
                    exportURL = IdentifiableValue(value: try service.exportTrainingSet(preferences: preferences))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .disabled(readiness.map { $0.reviewCount == 0 } ?? true)
        } header: {
            Text("Fit it yourself")
        } footer: {
            Text("A CSV in the format the published FSRS optimiser reads — one row per review, with the gap since that card's previous review. Run it through the optimiser and paste the weights below.")
        }
    }

    private var applySection: some View {
        Section {
            if isPasting {
                TextField("[0.4, 1.18, 3.17, …]", text: $pastedWeights, axis: .vertical)
                    .lineLimit(2...6)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Button("Cancel") {
                        isPasting = false
                        pastedWeights = ""
                    }
                    .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button("Apply") { apply() }
                        .fontWeight(.semibold)
                        .disabled(pastedWeights.isEmpty)
                }
            } else {
                Button("Paste fitted weights") {
                    // Pre-fill from the clipboard: the user has just copied them out of the
                    // optimiser, and making them paste again is pure friction.
                    pastedWeights = UIPasteboard.general.string ?? ""
                    isPasting = true
                }
            }
            if let message {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.success)
            }
        } footer: {
            Text("Needs exactly \(FSRSParameters.fsrs5WeightCount) numbers. Your cards keep the stability and difficulty they have already earned — only the scheduling of future reviews changes.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Go back to the default weights", role: .destructive) {
                guard let preferences = dependencies.preferences else { return }
                do {
                    try service.resetToDefaultWeights(preferences: preferences)
                    message = nil
                    refresh()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var explanationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Why this exists")
                    .font(Typography.sectionHeader)
                Text("FSRS ships with weights fitted to a large pool of learners. Your memory is not the average of that pool — you may hold vocabulary longer than it assumes, or forget faster, and the same is true word by word.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                Text("Every review you do is recorded with what the model predicted at the time. That record is what makes fitting the model to you possible, and it is why the review history is never deleted — not even when you reset a card.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                Text("Fitting inside the app is not built yet. Until it is, the export above lets you do it with the published tooling.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.vertical, Spacing.xxs)
        }
    }

    // MARK: - Actions

    private func refresh() {
        guard let preferences = dependencies.preferences else { return }
        readiness = try? service.readiness(preferences: preferences)
    }

    private func apply() {
        guard let preferences = dependencies.preferences else { return }
        guard let weights = OptimizerService.parseWeights(pastedWeights) else {
            errorMessage = "That does not look like a list of numbers. Paste the weights exactly as the optimiser printed them."
            return
        }
        do {
            try service.applyFittedWeights(
                weights,
                preferences: preferences,
                reviewCount: readiness?.reviewCount ?? 0
            )
            dependencies.savePreferences()
            isPasting = false
            pastedWeights = ""
            message = "Applied. Your next reviews will be scheduled with these weights."
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { OptimizerSettingsView() }
}
