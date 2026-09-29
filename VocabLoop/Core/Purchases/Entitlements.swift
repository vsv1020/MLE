import Foundation
import Observation

/// What VocabLoop Plus unlocks, and whether this device has it.
///
/// One lifetime, non-consumable purchase. Studying itself is never behind it: every card,
/// every review, the daily goal, pronunciation and the whole starter pack stay free. Plus adds
/// *more* — larger word packs and personal tuning — so a free user never hits a wall mid-habit.
public enum PlusCatalog {
    /// App Store Connect product ID. Must match the in-app purchase exactly.
    public static let lifetimeProductID = "com.vocabloop.app.plus.lifetime"

    /// Content packs that introduce new words only for Plus. Everything else — the A1–A2 core,
    /// the language starters, the user's own decks — is free.
    public static let premiumDeckSlugs: Set<String> = ["en_core_b1_b2", "en_core_c1"]

    public static func requiresPlus(deckSlug: String) -> Bool {
        premiumDeckSlugs.contains(deckSlug)
    }
}

extension Deck {
    /// `true` for a pack that offers new words only with Plus.
    public var requiresPlus: Bool { PlusCatalog.requiresPlus(deckSlug: slug) }
}

/// The unlock flag, cached so the app knows it offline and before StoreKit answers.
///
/// StoreKit's `Transaction.currentEntitlements` is the source of truth and is re-read at every
/// launch by ``PurchaseService``; this only remembers the last answer so a cold start on a plane
/// does not briefly lock a paying user out of their packs.
@MainActor
@Observable
public final class Entitlements {
    public static let shared = Entitlements()

    public private(set) var isPlus: Bool

    private let defaults: UserDefaults?
    private static let key = "plus.lifetime.unlocked"

    /// - Parameter defaults: `nil` keeps the flag in memory only, which is what tests want.
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        self.isPlus = defaults?.bool(forKey: Self.key) ?? false
    }

    public func setPlus(_ value: Bool) {
        guard value != isPlus else { return }
        isPlus = value
        defaults?.set(value, forKey: Self.key)
    }
}
