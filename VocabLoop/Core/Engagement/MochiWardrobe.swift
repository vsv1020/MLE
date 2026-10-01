import SwiftUI

/// How grown-up Mochi looks. Derived from the level — see ``RewardEngine/stage(forLevel:)``.
public enum MochiStage: Int, Sendable {
    /// L1–4.
    case sprout
    /// L5–9: a tiny leaf tuft.
    case kid
    /// L10–14: bigger blush, a star on the belly.
    case teen
    /// L15+: a sparkle crown line.
    case grown
}

/// Something Mochi can wear. Every item is drawn in `Canvas` — there are no image assets.
///
/// **Level unlocks are always free.** A child never earns something they then cannot wear; only
/// the Plus closet (four extra items) needs Plus, and those are extras, never progress.
public enum MochiAccessory: String, CaseIterable, Codable, Sendable {
    case redScarf
    case partyHat
    case roundGlasses
    case bow
    case strawHat
    case crown
    case headphones
    case cape
    case nightcap
    case sunVisor
    case goldStarPin
    case graduationCap
    case wizardHat
    case halo
    case rainbowScarf
    case astronautHelmet

    /// Where an accessory sits. One item per slot may be worn at a time.
    public enum Slot: String, CaseIterable, Sendable {
        case head
        case eyes
        case neck
        case back
    }

    public var slot: Slot {
        switch self {
        case .redScarf, .goldStarPin, .rainbowScarf: return .neck
        case .roundGlasses: return .eyes
        case .cape: return .back
        case .partyHat, .bow, .strawHat, .crown, .headphones, .nightcap, .sunVisor,
             .graduationCap, .wizardHat, .halo, .astronautHelmet:
            return .head
        }
    }

    public var name: String {
        switch self {
        case .redScarf: return "Red scarf"
        case .partyHat: return "Party hat"
        case .roundGlasses: return "Round glasses"
        case .bow: return "Bow"
        case .strawHat: return "Straw hat"
        case .crown: return "Crown"
        case .headphones: return "Headphones"
        case .cape: return "Cape"
        case .nightcap: return "Nightcap"
        case .sunVisor: return "Sun visor"
        case .goldStarPin: return "Gold star pin"
        case .graduationCap: return "Graduation cap"
        case .wizardHat: return "Wizard hat"
        case .halo: return "Halo"
        case .rainbowScarf: return "Rainbow scarf"
        case .astronautHelmet: return "Astronaut helmet"
        }
    }

    /// Mochi level that unlocks this item, or `nil` when something else does.
    public var unlockLevel: Int? {
        switch self {
        case .redScarf: return 2
        case .partyHat: return 3
        case .roundGlasses: return 4
        case .bow: return 5
        case .strawHat: return 6
        case .crown: return 8
        case .headphones: return 10
        case .cape: return 12
        case .nightcap, .sunVisor, .goldStarPin, .graduationCap,
             .wizardHat, .halo, .rainbowScarf, .astronautHelmet:
            return nil
        }
    }

    /// Achievement that unlocks this item, or `nil` when something else does.
    public var unlockAchievement: AchievementID? {
        switch self {
        case .nightcap: return .night_owl
        case .sunVisor: return .early_bird
        case .goldStarPin: return .combo_50
        case .graduationCap: return .mastered_100
        case .redScarf, .partyHat, .roundGlasses, .bow, .strawHat, .crown, .headphones, .cape,
             .wizardHat, .halo, .rainbowScarf, .astronautHelmet:
            return nil
        }
    }

    /// `true` for the Plus closet. ``PlusCatalog/plusClosetAccessoryIDs`` is the one list.
    public var requiresPlus: Bool {
        PlusCatalog.plusClosetAccessoryIDs.contains(rawValue)
    }
}

/// Mochi's body colour.
public enum MochiBodyColor: String, CaseIterable, Codable, Sendable {
    case vanilla
    case strawberry
    case matcha
    case blueberry
    case mango
    case lavender
    case mint
    case cocoa
    case galaxy

    public var name: String {
        switch self {
        case .vanilla: return "Vanilla"
        case .strawberry: return "Strawberry"
        case .matcha: return "Matcha"
        case .blueberry: return "Blueberry"
        case .mango: return "Mango"
        case .lavender: return "Lavender"
        case .mint: return "Mint"
        case .cocoa: return "Cocoa"
        case .galaxy: return "Galaxy"
        }
    }

    /// Level that unlocks this colour; `1` for the default; `nil` for the Plus closet.
    public var unlockLevel: Int? {
        switch self {
        case .vanilla: return 1
        case .strawberry: return 3
        case .matcha: return 5
        case .blueberry: return 7
        case .mango: return 9
        case .lavender, .mint, .cocoa, .galaxy: return nil
        }
    }

    /// `true` for the Plus closet. ``PlusCatalog/plusClosetColorIDs`` is the one list.
    public var requiresPlus: Bool {
        PlusCatalog.plusClosetColorIDs.contains(rawValue)
    }

    /// Body fill.
    ///
    /// Vanilla *is* ``Palette/surface``, so a Mochi nobody has dressed draws exactly as it did
    /// before 1.0.7. Every other colour is a pale pastel on paper and a muted dark tone on the
    /// blackboard: the face is drawn in ``Palette/textPrimary``, which is dark ink in light mode
    /// and chalk in dark mode, and it has to stay readable on every body.
    public var fill: Color {
        switch self {
        case .vanilla: return Palette.surface
        case .strawberry: return Color(light: 0xFBD3DA, dark: 0x5A3540)
        case .matcha: return Color(light: 0xD5E8C4, dark: 0x3D5236)
        case .blueberry: return Color(light: 0xCFDAF5, dark: 0x34405E)
        case .mango: return Color(light: 0xFDE0A8, dark: 0x5E4A28)
        case .lavender: return Color(light: 0xE3D7F5, dark: 0x4A3F5E)
        case .mint: return Color(light: 0xCDEFE3, dark: 0x2F5249)
        case .cocoa: return Color(light: 0xE3CBB5, dark: 0x4A3A30)
        case .galaxy: return Color(light: 0xC9C6EE, dark: 0x2B2A4A)
        }
    }
}

/// Everything needed to draw Mochi: stage, colour and what it is wearing.
///
/// A value, so the study card, the wardrobe, the recap card and the future widget all draw the
/// same Mochi from the same few fields.
public struct MochiLook: Equatable, Sendable {
    public var stage: MochiStage
    public var color: MochiBodyColor
    /// At most one per ``MochiAccessory/Slot``.
    public var accessories: [MochiAccessory]

    public init(stage: MochiStage, color: MochiBodyColor, accessories: [MochiAccessory]) {
        self.stage = stage
        self.color = color
        self.accessories = accessories
    }

    public static let `default` = MochiLook(stage: .sprout, color: .vanilla, accessories: [])
}
