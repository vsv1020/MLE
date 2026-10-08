import SwiftUI

/// VocabLoop Plus: what it adds, one price, buy or restore.
///
/// Leads with what is *free*, on purpose. The app is built so nobody hits a wall mid-habit,
/// and a paywall that implies otherwise would read as a bait-and-switch to the parent who
/// installed it for their child.
struct PlusView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var purchases: PurchaseService { dependencies.purchases }
    private var isPlus: Bool { dependencies.entitlements.isPlus }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                header

                CardContainer(style: .crayon) {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        benefit("books.vertical.fill", "更多词库",
                                "英语核心词 B1–B2 和 C1，以后新出的词库也都包含在内。")
                        benefit("brain.head.profile", "按你的记忆调节",
                                "根据你自己的复习记录调整复习安排。")
                        benefit("tshirt.fill", "麻薯的 Plus 衣橱",
                                "巫师帽、光环、彩虹围巾和宇航员头盔，还有薰衣草、薄荷、可可和星空四种颜色。")
                        benefit("chart.bar.doc.horizontal", "家长报告历史",
                                "一眼看到 12 周的进步，还能导出 PDF 保存或分享。")
                        benefit("heart.fill", "支持独立开发的 App",
                                "没有广告，没有追踪，不是订阅。只付一次，永久拥有。")
                    }
                }

                Text("永远免费：学习你已有的所有单词、复习、小测验、每日目标、发音、英语核心词 A1–A2 和你自己添加的单词；还有学习中赢得的一切：星星糖、麻薯的等级和所有已解锁的装扮、贴纸、徽章、本周回顾和本周的家长报告。")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)

                actions

                legal
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .screenBackground()
        .navigationTitle("麻薯 Plus")
        .navigationBarTitleDisplayMode(.inline)
        .alert("购买", isPresented: Binding(
            get: { purchases.lastError != nil },
            set: { if !$0 { purchases.clearError() } }
        )) {
            Button("好") { purchases.clearError() }
        } message: {
            Text(purchases.lastError ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            Mascot(mood: isPlus ? .cheer : .happy)
                .frame(width: 104, height: 86)
            Text(isPlus ? "你已拥有麻薯 Plus 🎉" : "麻薯 Plus")
                .accessibilityIdentifier("plus.title")
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.textPrimary)
            Text(isPlus ? "谢谢你支持麻薯背单词！这个 Apple ID 上的所有内容都已解锁。" : "一次购买，永久拥有。")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.lg)
    }

    private func benefit(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Palette.brandPrimary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: Spacing.sm) {
            if isPlus {
                PrimaryButton("完成", systemImage: "checkmark") { dismiss() }
            } else {
                switch purchases.state {
                case .purchasing:
                    ProgressView().frame(minHeight: LayoutMetrics.minimumTapTarget)
                case .pending:
                    Text("等待批准中。购买一经批准，麻薯 Plus 就会立即解锁。")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                case .idle:
                    if let price = purchases.displayPrice {
                        PrimaryButton("解锁麻薯 Plus · \(price)", systemImage: "sparkles") {
                            Task { await purchases.purchase() }
                        }
                    } else if purchases.hasLoaded {
                        Text("暂时无法从 App Store 获取麻薯 Plus，请稍后再试。")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    } else {
                        ProgressView().frame(minHeight: LayoutMetrics.minimumTapTarget)
                    }
                }
                PrimaryButton("恢复购买", role: .secondary) {
                    Task { await purchases.restore() }
                }
                .disabled(purchases.state == .purchasing)
            }
        }
    }

    @ViewBuilder
    private var legal: some View {
        HStack(spacing: Spacing.md) {
            if let terms = AppLinks.termsOfUse {
                Button("使用条款") { openURL(terms) }
            }
            if let privacy = AppLinks.privacyPolicy {
                Button("隐私政策") { openURL(privacy) }
            }
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.textSecondary)
    }
}

/// A "Plus" badge for locked features.
struct PlusBadge: View {
    var body: some View {
        Text("PLUS")
            .font(.system(.caption2, design: .rounded, weight: .heavy))
            .foregroundStyle(Palette.onBrand)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.brandSecondary))
            .accessibilityLabel("需要麻薯 Plus")
    }
}
