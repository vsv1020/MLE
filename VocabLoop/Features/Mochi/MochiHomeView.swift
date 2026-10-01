import SwiftUI

/// Mochi's home: Mochi and the wardrobe, the sticker book, and the badges.
///
/// **Present it as a sheet** — from the Mochi button on the study screen and from Today's Mochi
/// row. It owns its `NavigationStack` (albums and the Plus screen push inside it) and a Done
/// button, so the presenter only needs `.sheet { MochiHomeView() }`. Pushing it onto another
/// navigation stack would nest two stacks.
struct MochiHomeView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case mochi
        case stickers
        case badges

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mochi: return "Mochi"
            case .stickers: return "Stickers"
            case .badges: return "Badges"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var section: Pane

    init(initialSection: Pane = .mochi) {
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(Pane.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .readableWidth()

                switch section {
                case .mochi:
                    MochiWardrobeTab()
                case .stickers:
                    StickerBookView()
                case .badges:
                    AchievementsView()
                }
            }
            .screenBackground()
            .navigationTitle(section.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The first section: Mochi as they look now, the level card, and the wardrobe.
private struct MochiWardrobeTab: View {
    @Environment(\.appDependencies) private var dependencies

    @State private var snapshot = WardrobeSnapshot.empty
    @State private var mood: Mascot.Mood = .happy
    @State private var cheerTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Mascot(mood: mood, look: snapshot.look)
                    .frame(width: 160, height: 133)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.sm)

                MochiStatusCard(candy: snapshot.candy)

                Text("Every answer earns star candy, even \u{201C}Forgot\u{201D}. Candy helps Mochi grow and unlocks new things to wear.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)

                WardrobeView(
                    snapshot: snapshot,
                    isPlus: dependencies.entitlements.isPlus,
                    onToggle: toggle,
                    onColor: choose
                )
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .task { reload() }
        .onDisappear { cheerTask?.cancel() }
    }

    private func reload() {
        let engagement = dependencies.engagement
        guard let profile = try? engagement.profile() else { return }
        snapshot = WardrobeSnapshot(
            candy: profile.candyTotal,
            look: engagement.currentLook(),
            unlockedAchievements: profile.unlockedAchievementIDs,
            grantedAccessories: Set(profile.unlockedAccessoryIDs)
        )
    }

    private func toggle(_ accessory: MochiAccessory) {
        let isWorn = snapshot.look.accessories.contains(accessory)
        try? dependencies.engagement.setEquipped(isWorn ? nil : accessory, slot: accessory.slot)
        Haptics.tap()
        apply(cheer: !isWorn)
    }

    private func choose(_ color: MochiBodyColor) {
        guard color != snapshot.look.color else { return }
        try? dependencies.engagement.setBodyColor(color)
        Haptics.tap()
        apply(cheer: true)
    }

    /// Reload, and a short cheer for putting something on. Mochi hops on a mood change by
    /// itself (and does not under Reduce Motion). The new look itself is not animated: the body
    /// would glide to its new size while the drawn accessories jumped.
    private func apply(cheer: Bool) {
        reload()
        guard cheer else { return }
        cheerTask?.cancel()
        mood = .cheer
        cheerTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            mood = .happy
        }
    }
}
