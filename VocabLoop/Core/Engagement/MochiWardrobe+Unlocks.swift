import Foundation

// The unlock routes that need app-only types (`AchievementID` lives with `EngagementProfile`,
// `PlusCatalog` with `Deck`). Split out of `VocabLoopShared/MochiWardrobe.swift` so the widget
// extension can draw Mochi without compiling the store's models.

public extension MochiAccessory {
    /// Achievement that unlocks this item, or `nil` when something else does.
    var unlockAchievement: AchievementID? {
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
    var requiresPlus: Bool {
        PlusCatalog.plusClosetAccessoryIDs.contains(rawValue)
    }
}

public extension MochiBodyColor {
    /// `true` for the Plus closet. ``PlusCatalog/plusClosetColorIDs`` is the one list.
    var requiresPlus: Bool {
        PlusCatalog.plusClosetColorIDs.contains(rawValue)
    }
}
