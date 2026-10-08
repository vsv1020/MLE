import SwiftUI

/// What the wardrobe needs to know about the learner, read once from the engagement profile.
struct WardrobeSnapshot: Equatable {
    var candy: Int
    var look: MochiLook
    var unlockedAchievements: Set<String>
    var grantedAccessories: Set<String>

    var level: Int { RewardEngine.level(forCandy: candy) }

    static let empty = WardrobeSnapshot(candy: 0, look: .default, unlockedAchievements: [], grantedAccessories: [])
}

/// Every accessory and body colour, grouped by slot, each tile showing Mochi wearing it.
///
/// **Locked items say how they open, never what they cost.** A level item shows "Level 8"; a badge
/// item names the badge; a Plus closet item shows a "Plus" label and links to ``PlusView`` — the
/// one screen that sells anything, written for the grown-up. There is no buy button here.
///
/// Stateless: the parent owns the snapshot and applies changes through the engagement service, so
/// the preview Mochi above the wardrobe and these tiles can never disagree.
struct WardrobeView: View {
    let snapshot: WardrobeSnapshot
    let isPlus: Bool
    let onToggle: (MochiAccessory) -> Void
    let onColor: (MochiBodyColor) -> Void

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: Spacing.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ForEach(MochiAccessory.Slot.allCases, id: \.self) { slot in
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionHeader(WardrobeRules.slotTitle(slot))
                    LazyVGrid(columns: columns, spacing: Spacing.sm) {
                        ForEach(MochiAccessory.allCases.filter { $0.slot == slot }, id: \.self) { accessory in
                            accessoryTile(accessory)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader("颜色")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: Spacing.sm)], spacing: Spacing.sm) {
                    ForEach(MochiBodyColor.allCases, id: \.self) { color in
                        colorTile(color)
                    }
                }
            }

            if !isPlus {
                Text("标着 Plus 的是麻薯 Plus 的额外装扮。通过等级和徽章赢得的装扮永远归你，随时可以穿戴。")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    // MARK: - Accessories

    @ViewBuilder
    private func accessoryTile(_ accessory: MochiAccessory) -> some View {
        let lock = WardrobeRules.lock(
            for: accessory, level: snapshot.level,
            unlockedAchievements: snapshot.unlockedAchievements,
            grantedAccessories: snapshot.grantedAccessories, isPlus: isPlus
        )
        let isWorn = snapshot.look.accessories.contains(accessory)
        let preview = MochiLook(stage: snapshot.look.stage, color: snapshot.look.color, accessories: [accessory])

        switch lock {
        case .unlocked:
            Button {
                onToggle(accessory)
            } label: {
                WardrobeTile(
                    title: accessory.name, lock: lock, isSelected: isWorn,
                    seed: WobbleShape.seed(for: accessory.rawValue)
                ) {
                    Mascot(mood: .happy, look: preview).still()
                }
            }
            .pressable(scale: 0.95)
            .accessibilityLabel(isWorn ? "\(accessory.name)，正在穿戴" : accessory.name)
            .accessibilityHint(isWorn ? "轻点两下取下" : "轻点两下穿上")
            .accessibilityAddTraits(isWorn ? .isSelected : [])
        case .plus:
            NavigationLink {
                PlusView()
            } label: {
                WardrobeTile(
                    title: accessory.name, lock: lock, isSelected: false,
                    seed: WobbleShape.seed(for: accessory.rawValue)
                ) {
                    Mascot(mood: .happy, look: preview).still()
                }
            }
            .pressable(scale: 0.95)
            .accessibilityLabel("\(accessory.name)。\(WardrobeRules.spokenLock(for: lock))")
        case .level, .achievement:
            WardrobeTile(
                title: accessory.name, lock: lock, isSelected: false,
                seed: WobbleShape.seed(for: accessory.rawValue)
            ) {
                Mascot(mood: .happy, look: preview).still()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(accessory.name)。\(WardrobeRules.spokenLock(for: lock))")
        }
    }

    // MARK: - Colours

    @ViewBuilder
    private func colorTile(_ color: MochiBodyColor) -> some View {
        let lock = WardrobeRules.lock(for: color, level: snapshot.level, isPlus: isPlus)
        let isWorn = snapshot.look.color == color
        let swatch = ColorSwatch(color: color, lock: lock, isSelected: isWorn)

        switch lock {
        case .unlocked:
            Button {
                onColor(color)
            } label: {
                swatch
            }
            .pressable(scale: 0.94)
            .accessibilityLabel(isWorn ? "\(color.name)，已选择" : color.name)
            .accessibilityHint(isWorn ? "" : "轻点两下，把麻薯换成\(color.name.lowercased())")
            .accessibilityAddTraits(isWorn ? .isSelected : [])
        case .plus:
            NavigationLink {
                PlusView()
            } label: {
                swatch
            }
            .pressable(scale: 0.94)
            .accessibilityLabel("\(color.name)。\(WardrobeRules.spokenLock(for: lock))")
        case .level, .achievement:
            swatch
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(color.name)。\(WardrobeRules.spokenLock(for: lock))")
        }
    }
}

// MARK: - Tiles

/// One wardrobe item: a preview Mochi on a drawn panel, its name, and how it opens.
private struct WardrobeTile<Preview: View>: View {
    let title: String
    let lock: WardrobeLock
    let isSelected: Bool
    let seed: UInt64
    @ViewBuilder let preview: () -> Preview

    private var isLocked: Bool { lock != .unlocked }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            preview()
                .frame(width: 80, height: 67)
                // A locked item is shown, not hidden — seeing the crown is the reason to reach
                // level 8 — but drained of colour so it does not read as already yours.
                .saturation(isLocked ? 0 : 1)
                .opacity(isLocked ? 0.5 : 1)
                .overlay(alignment: .topTrailing) {
                    if isLocked {
                        Image(systemName: lock == .plus ? "sparkles" : "lock.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityHidden(true)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(Palette.brandPrimary)
                            .background(Circle().fill(Palette.surface))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.top, Spacing.xs)

            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)

            if let label = WardrobeRules.label(for: lock) {
                Chip(label, color: lock == .plus ? Palette.brandSecondary : Palette.textSecondary,
                     systemImage: lock == .plus ? nil : "lock.fill")
            } else {
                Chip(isSelected ? "穿戴中" : "穿上", color: isSelected ? Palette.success : Palette.brandPrimary)
            }
        }
        .padding(Spacing.xs)
        .frame(maxWidth: .infinity)
        .background {
            let shape = WobbleShape(cornerRadius: Radius.nested, amplitude: 1.0, seed: seed)
            shape.fill(isSelected ? Palette.brandPrimary.opacity(0.12) : Palette.surfaceRaised)
                .overlay(
                    shape.stroke(
                        isSelected ? Palette.brandPrimary : Palette.separator.opacity(0.55),
                        lineWidth: isSelected ? 2.5 : 1.5
                    )
                )
        }
        .contentShape(Rectangle())
    }
}

/// A body colour: a drawn blob of the colour, its name, and how it opens.
private struct ColorSwatch: View {
    let color: MochiBodyColor
    let lock: WardrobeLock
    let isSelected: Bool

    private var isLocked: Bool { lock != .unlocked }

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            let shape = WobbleShape(cornerRadius: 22, amplitude: 0.8, seed: WobbleShape.seed(for: color.rawValue))
            ZStack {
                shape.fill(color.fill)
                    .overlay(shape.stroke(Palette.separator, lineWidth: 1.5))
                if isLocked {
                    Image(systemName: lock == .plus ? "sparkles" : "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.textPrimary)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            .frame(width: 48, height: 44)
            .padding(3)
            .overlay {
                if isSelected {
                    WobbleShape(cornerRadius: 25, amplitude: 0.8, seed: WobbleShape.seed(for: color.rawValue) &+ 1)
                        .stroke(Palette.brandPrimary, lineWidth: 2.5)
                }
            }
            .accessibilityHidden(true)

            Text(color.name)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let label = WardrobeRules.label(for: lock) {
                Text(label)
                    .font(Typography.chip)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .tappableArea()
    }
}
