import Foundation
import SwiftData

/// A named collection of entries — a built-in content pack or a user's own list.
///
/// Decks scope *what may be introduced*, not what is due. A review session always
/// draws from everything the user has enrolled, because splitting reviews by deck is
/// how people end up with a backlog in the deck they stopped opening.
@Model
public final class Deck {
    /// Stable identity: the seed pack name for built-ins, a UUID for user decks.
    @Attribute(.unique) public var slug: String

    public var name: String
    public var summary: String
    public var languageCode: String

    /// Built-in decks are replaced by seed import and cannot be deleted or renamed.
    public var isBuiltIn: Bool

    public var sortOrder: Int
    /// Hex string, e.g. `"#4F46E5"`. `nil` uses the brand colour.
    public var colorHex: String?
    public var symbolName: String

    /// Included when the daily batch picks new words. Lets a user park a deck without
    /// deleting it.
    public var isActiveForNewWords: Bool

    public var createdAt: Date
    public var updatedAt: Date

    /// The inverse is declared on `Entry.decks`.
    public var entries: [Entry]

    public init(
        slug: String,
        name: String,
        summary: String = "",
        languageCode: String,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0,
        colorHex: String? = nil,
        symbolName: String = "square.stack.3d.up",
        isActiveForNewWords: Bool = true,
        now: Date = Date()
    ) {
        self.slug = slug
        self.name = name
        self.summary = summary
        self.languageCode = languageCode
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.isActiveForNewWords = isActiveForNewWords
        self.createdAt = now
        self.updatedAt = now
        self.entries = []
    }

    public var language: LearningLanguage? { LearningLanguage(code: languageCode) }

    public var entryCount: Int { entries.count }

    /// Entries the user has actually enrolled (i.e. that have cards).
    public var enrolledCount: Int { entries.filter(\.isEnrolled).count }

    public var progress: Double {
        guard entryCount > 0 else { return 0 }
        return Double(enrolledCount) / Double(entryCount)
    }

    public static func userDeckSlug() -> String { "user-\(UUID().uuidString)" }
}
