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
                        benefit("books.vertical.fill", "More word packs",
                                "English Core B1–B2 and C1 — every future pack included.")
                        benefit("brain.head.profile", "Tuned to your memory",
                                "Fit the scheduler to your own review history.")
                        benefit("tshirt.fill", "Mochi's Plus closet",
                                "A wizard hat, a halo, a rainbow scarf and an astronaut helmet, plus lavender, mint, cocoa and galaxy colours.")
                        benefit("chart.bar.doc.horizontal", "Parent report history",
                                "Twelve weeks of progress at a glance, and a PDF to save or share.")
                        benefit("heart.fill", "Support an independent app",
                                "No ads, no tracking, no subscription. Pay once, keep it forever.")
                    }
                }

                Text("Always free: studying every word you have, reviews, quizzes, the daily goal, pronunciation, the A1–A2 core and your own words — and everything a learner earns: star candy, Mochi's levels and every unlocked outfit, stickers, badges, the weekly recap and this week's parent report.")
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
        .navigationTitle("VocabLoop Plus")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Purchase", isPresented: Binding(
            get: { purchases.lastError != nil },
            set: { if !$0 { purchases.clearError() } }
        )) {
            Button("OK") { purchases.clearError() }
        } message: {
            Text(purchases.lastError ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            Mascot(mood: isPlus ? .cheer : .happy)
                .frame(width: 104, height: 86)
            Text(isPlus ? "You have Plus 🎉" : "VocabLoop Plus")
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.textPrimary)
            Text(isPlus ? "Thank you for supporting VocabLoop. Everything is unlocked on this Apple ID." : "One purchase. Yours for good.")
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
                PrimaryButton("Done", systemImage: "checkmark") { dismiss() }
            } else {
                switch purchases.state {
                case .purchasing:
                    ProgressView().frame(minHeight: LayoutMetrics.minimumTapTarget)
                case .pending:
                    Text("Waiting for approval. Plus unlocks as soon as the purchase is approved.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                case .idle:
                    if let price = purchases.displayPrice {
                        PrimaryButton("Unlock Plus · \(price)", systemImage: "sparkles") {
                            Task { await purchases.purchase() }
                        }
                    } else if purchases.hasLoaded {
                        Text("Plus is not available from the App Store right now. Please try again later.")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    } else {
                        ProgressView().frame(minHeight: LayoutMetrics.minimumTapTarget)
                    }
                }
                PrimaryButton("Restore purchase", role: .secondary) {
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
                Button("Terms of Use") { openURL(terms) }
            }
            if let privacy = AppLinks.privacyPolicy {
                Button("Privacy Policy") { openURL(privacy) }
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
            .accessibilityLabel("Requires Plus")
    }
}
