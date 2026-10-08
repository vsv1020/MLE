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
        .navigationTitle("按我的记忆调节")
        .task { refresh() }
        .sheet(item: $exportURL) { wrapper in
            ShareLink(item: wrapper.value) {
                Label("分享复习记录", systemImage: "square.and.arrow.up")
            }
            .padding(Spacing.lg)
            .presentationDetents([.height(160)])
        }
        .alert("没能完成", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var readinessSection: some View {
        Section {
            if let readiness {
                LabeledContent("已记录的复习", value: "\(readiness.reviewCount)")
                LabeledContent("涉及的卡片", value: "\(readiness.cardCount)")
                LabeledContent(
                    "当前使用",
                    value: readiness.hasFittedWeights ? "你拟合的参数" : "默认参数"
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
            Text("你的记录")
        }
    }

    private var exportSection: some View {
        Section {
            Button("导出我的复习记录") {
                guard let preferences = dependencies.preferences else { return }
                do {
                    exportURL = IdentifiableValue(value: try service.exportTrainingSet(preferences: preferences))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .disabled(readiness.map { $0.reviewCount == 0 } ?? true)
        } header: {
            Text("自己拟合")
        } footer: {
            Text("导出 FSRS 官方优化器能读取的 CSV 文件：每次复习一行，附带与这张卡片上一次复习的间隔。用优化器跑一遍，再把得到的参数粘贴到下面。")
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
                    Button("取消") {
                        isPasting = false
                        pastedWeights = ""
                    }
                    .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button("应用") { apply() }
                        .fontWeight(.semibold)
                        .disabled(pastedWeights.isEmpty)
                }
            } else {
                Button("粘贴拟合好的参数") {
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
            Text("必须正好是 \(FSRSParameters.fsrs5WeightCount) 个数字。卡片已有的稳定度和难度会保留，只有之后的复习安排会改变。")
        }
    }

    private var resetSection: some View {
        Section {
            Button("恢复默认参数", role: .destructive) {
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
                Text("为什么有这个功能")
                    .font(Typography.sectionHeader)
                Text("FSRS 自带的参数是根据大量学习者拟合出来的。可你的记忆并不等于他们的平均值：你可能比它假设的记得更久，也可能忘得更快，每个单词也各不相同。")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                Text("你的每次复习都会连同模型当时的预测一起记录下来。有了这些记录，才能为你拟合模型，所以复习记录永远不会删除，重置卡片时也不会。")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                Text("App 内还不能直接拟合。在那之前，可以用上面的导出功能配合官方工具自己完成。")
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
            errorMessage = "这看起来不是一串数字。请按优化器输出的原样粘贴参数。"
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
            message = "已应用。之后的复习会按这些参数安排。"
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { OptimizerSettingsView() }
}
