import Foundation

/// Something worth sharing, as plain values (sharing plan §1).
///
/// Every payload is built by the screen that offers the button, from state it already holds, and
/// carries only facts that are safe to leave the device: counts, Mochi's look, dictionary content.
/// **Never** a name, an email, an account ID or anything a child typed — `ShareCardPrivacyTests`
/// walks every payload with `Mirror` to keep it that way. Rendering touches no store.
enum ShareCard: Sendable {
    case goalComplete(GoalCard)
    case streak(StreakCard)
    case badge(BadgeCard)
    case mochi(MochiCard)
    case word(WordCard)
    case album(AlbumCard)
    case week(WeeklyRecap)

    /// The card's kind, without its payload. Seeds the crayon border and names the file.
    enum Kind: String, CaseIterable, Sendable {
        case goal
        case streak
        case badge
        case mochi
        case word
        case album
        case week
    }

    var kind: Kind {
        switch self {
        case .goalComplete: return .goal
        case .streak: return .streak
        case .badge: return .badge
        case .mochi: return .mochi
        case .word: return .word
        case .album: return .album
        case .week: return .week
        }
    }

    /// The one sentence the card leads with; also the share sheet's preview title.
    var headline: String {
        switch self {
        case .goalComplete(let card): return ShareCopy.goalHeadline(reviews: card.reviewsToday)
        case .streak(let card): return ShareCopy.streakHeadline(days: card.streak)
        case .badge(let card): return ShareCopy.badgeHeadline(name: card.name)
        case .mochi(let card): return ShareCopy.mochiHeadline(level: card.level)
        case .word(let card): return ShareCopy.wordHeadline(headword: card.headword)
        case .album(let card): return ShareCopy.albumHeadline(stickers: card.stickerCount)
        case .week(let recap): return RecapCopy.headline(wordsMastered: recap.wordsMastered)
        }
    }

    /// The text that travels with the image: headline plus the App Store link.
    var message: String { ShareCopy.message(headline: headline) }

    var accessibilityLabel: String { "分享卡片：\(headline)" }

    /// Stable for the same card, so a re-render overwrites rather than piling up files, e.g.
    /// `麻薯背单词-goal-2026-10-01.png`.
    var fileName: String {
        let stem: String
        switch self {
        case .goalComplete(let card):
            stem = "goal-\(card.dayKey)"
        case .streak(let card):
            stem = "streak-\(max(0, card.streak))"
        case .badge(let card):
            stem = "badge-\(card.id.rawValue)"
        case .mochi(let card):
            stem = "mochi-level-\(max(1, card.level))"
        case .word(let card):
            stem = "word-\(card.languageCode)-\(card.headword)"
        case .album(let card):
            stem = "album-\(card.albumLevel)-\(card.familyTitle)-\(card.page)"
        case .week(let recap):
            stem = "my-week-\(recap.weekStartKey)"
        }
        return "麻薯背单词-\(Self.sanitized(stem)).png"
    }

    /// Letters, digits and hyphens only: a headword like "c'est" or "à la carte" must still be a
    /// safe single path component.
    static func sanitized(_ raw: String) -> String {
        var result = ""
        var lastWasHyphen = false
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "card" : trimmed
    }

    /// A day key (`yyyy-MM-dd`) for the goal card's file name when the caller has no
    /// ``StudyCalendar`` at hand.
    static func dayKey(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - Payloads

/// Today's goal met. Offered on the goal screen only, never on the resting screen.
struct GoalCard: Equatable, Sendable {
    var reviewsToday: Int
    var dailyGoal: Int
    var streak: Int
    var minutes: Int
    var look: MochiLook
    var level: Int
    /// The study day the goal was met on; names the file.
    var dayKey: String
}

/// A running streak. Offered from three days.
struct StreakCard: Equatable, Sendable {
    /// Streaks below this are not offered for sharing — one or two days is not yet a habit.
    static let minimumToShare = 3

    var streak: Int
    var longest: Int
    var look: MochiLook
    var level: Int
}

/// An earned badge.
struct BadgeCard: Equatable, Sendable {
    var id: AchievementID
    var name: String
    var detail: String
    var symbolName: String
    /// Shown as a date only ("Earned 12 Sep").
    var unlockedAt: Date?
    var look: MochiLook
    var level: Int

    init(id: AchievementID, name: String, detail: String, symbolName: String, unlockedAt: Date?, look: MochiLook, level: Int) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbolName = symbolName
        self.unlockedAt = unlockedAt
        self.look = look
        self.level = level
    }

    /// `nil` for a badge not yet earned: only earned badges are shared.
    init?(status: AchievementStatus, look: MochiLook, level: Int) {
        guard let unlockedAt = status.unlockedAt else { return nil }
        let achievement = status.achievement
        self.init(
            id: achievement.id,
            name: achievement.name,
            detail: achievement.detail,
            symbolName: achievement.symbolName,
            unlockedAt: unlockedAt,
            look: look,
            level: level
        )
    }
}

/// Mochi as they look now. Doubles as the level-up share.
struct MochiCard: Equatable, Sendable {
    var look: MochiLook
    var level: Int
    var candy: Int
    var stageName: String
}

/// A dictionary word. **Bundled entries only** — see ``make(from:look:)``.
struct WordCard: Equatable, Sendable {
    var headword: String
    var phonetic: String?
    var definition: String
    var example: String?
    /// The example with the target span marked (`"She {{lent}} me…"`), when the pack has one.
    var exampleCloze: String?
    var languageCode: String
    var look: MochiLook

    /// The only place a share card touches a model, and it copies plain strings out.
    ///
    /// `nil` for a user-created entry — it can contain anything a child typed — and for an entry
    /// without a sense or definition, which has nothing to show.
    static func make(from entry: Entry, look: MochiLook = .default) -> WordCard? {
        guard !entry.isUserCreated else { return nil }
        let senses = entry.orderedSenses
        guard let sense = senses.first else { return nil }
        let definition = sense.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definition.isEmpty else { return nil }
        let example = sense.examples.first ?? senses.lazy.compactMap { $0.examples.first }.first
        let phonetic = entry.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WordCard(
            headword: entry.headword,
            phonetic: (phonetic?.isEmpty ?? true) ? nil : phonetic,
            definition: definition,
            example: example?.text,
            exampleCloze: example?.cloze,
            languageCode: entry.languageCode,
            look: look
        )
    }
}

/// A sticker-book page where every sticker shines.
struct AlbumCard: Equatable, Sendable {
    /// "A1 Nouns · Page 3".
    var albumTitle: String
    var familyTitle: String
    /// The album's CEFR band, "A1".
    var albumLevel: String
    var page: Int
    var stickerCount: Int
    var look: MochiLook
    /// Mochi's level, for the hero.
    var level: Int
}
