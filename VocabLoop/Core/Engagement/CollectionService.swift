import SwiftUI
import SwiftData

/// The sticker-book family a word belongs to, from its primary part of speech.
///
/// Four families rather than fifteen parts of speech: a child scans "Nouns" and "Little words",
/// not "Determiners" and "Conjunctions".
public enum WordFamily: String, CaseIterable, Codable, Sendable {
    case nouns
    case verbs
    case describingWords
    case littleWords

    public init(partOfSpeech: PartOfSpeech) {
        switch partOfSpeech {
        case .noun:
            self = .nouns
        case .verb:
            self = .verbs
        case .adjective, .adverb:
            self = .describingWords
        case .pronoun, .preposition, .conjunction, .determiner, .interjection, .numeral,
             .particle, .classifier, .phrase, .idiom, .other:
            self = .littleWords
        }
    }

    public var title: String {
        switch self {
        case .nouns: return "名词"
        case .verbs: return "动词"
        case .describingWords: return "描述词"
        case .littleWords: return "小词"
        }
    }

    /// Sticker chip tint. Existing palette tokens, so both appearances are already covered.
    public var tint: Color {
        switch self {
        case .nouns: return Palette.brandPrimary
        case .verbs: return Palette.brandSecondary
        case .describingWords: return Palette.success
        case .littleWords: return Palette.warning
        }
    }
}

/// Album difficulty band. C2 folds into C1: there are too few C2 words for pages of their own.
public enum AlbumLevel: String, CaseIterable, Sendable {
    case a1 = "A1"
    case a2 = "A2"
    case b1 = "B1"
    case b2 = "B2"
    case c1 = "C1"

    /// A word with no CEFR level (a user's own word, a starter pack without levels) goes in A1:
    /// the first pages a learner opens, which is where their own words belong.
    public init(cefr: CEFRLevel?) {
        switch cefr {
        case .none, .some(.a1): self = .a1
        case .some(.a2): self = .a2
        case .some(.b1): self = .b1
        case .some(.b2): self = .b2
        case .some(.c1), .some(.c2): self = .c1
        }
    }
}

/// One sticker-book page: up to ``pageSize`` words of one level and family.
///
/// Derived and stored nowhere. Entries carry no topic tags, so an album is a deterministic slice
/// of (level, family, frequency order) — the same words on the same page on every device and on
/// every launch, with nothing to migrate.
public struct Album: Identifiable, Hashable, Sendable {
    /// `"en|A1|nouns|3"`. Persisted in ``EngagementProfile/completedAlbumIDs``, so the format is
    /// frozen.
    public let id: String
    public let languageCode: String
    public let level: AlbumLevel
    public let family: WordFamily
    /// 1-based.
    public let page: Int
    /// In page order, at most ``pageSize``.
    public let entryStableIDs: [String]

    /// A 3×4 grid.
    public static let pageSize = 12

    public init(languageCode: String, level: AlbumLevel, family: WordFamily, page: Int, entryStableIDs: [String]) {
        self.id = Album.makeID(languageCode: languageCode, level: level, family: family, page: page)
        self.languageCode = languageCode
        self.level = level
        self.family = family
        self.page = page
        self.entryStableIDs = entryStableIDs
    }

    /// "A1 Nouns · Page 3".
    public var title: String { "\(level.rawValue) \(family.title) · 第 \(page) 页" }

    public static func makeID(languageCode: String, level: AlbumLevel, family: WordFamily, page: Int) -> String {
        "\(languageCode)|\(level.rawValue)|\(family.rawValue)|\(page)"
    }
}

/// How a word's sticker looks.
public enum StickerState: Sendable {
    /// Not enrolled: a dotted outline.
    case locked
    /// New or learning: a grey pencil sketch.
    case sketch
    /// Young: coloured in.
    case coloured
    /// Mature: coloured with a shine. What "complete" counts.
    case shiny

    public init(maturity: CardMaturity?, isEnrolled: Bool) {
        guard isEnrolled, let maturity else {
            self = .locked
            return
        }
        switch maturity {
        case .new, .learning: self = .sketch
        case .young: self = .coloured
        case .mature: self = .shiny
        }
    }
}

/// An album and the state of each of its stickers, in page order.
public struct AlbumProgress: Sendable {
    public var album: Album
    /// One per ``Album/entryStableIDs``, same order.
    public var states: [StickerState]

    public init(album: Album, states: [StickerState]) {
        self.album = album
        self.states = states
    }

    public var shinyCount: Int {
        states.filter { state in
            if case .shiny = state { return true }
            return false
        }.count
    }

    /// Every sticker on the page shines. A short last page completes at its own size.
    public var isComplete: Bool { !states.isEmpty && shinyCount == states.count }
}

/// How words are grouped into albums.
public enum AlbumGrouping: Sendable {
    /// Level × family × frequency pages. The 1.0.7 behaviour.
    case levelAndFamily
    /// Topic tags, once a content pass adds them (1.0.8). Until then it groups as
    /// ``levelAndFamily`` so nothing downstream has to know which is active.
    case tags
}

/// Builds the sticker book and reports progress through it.
@MainActor
public final class CollectionService {
    private let context: ModelContext
    private let grouping: AlbumGrouping
    /// Albums per language. Albums are a pure function of the dictionary, which only changes on
    /// a content import — so call ``invalidateCache()`` after one.
    private var cache: [String: [Album]] = [:]

    public init(context: ModelContext, grouping: AlbumGrouping = .levelAndFamily) {
        self.context = context
        self.grouping = grouping
    }

    public func albums(languageCode: String) throws -> [Album] {
        if let cached = cache[languageCode] { return cached }
        let entries = try context.fetch(
            FetchDescriptor<Entry>(predicate: #Predicate { $0.languageCode == languageCode })
        )
        let rows: [(stableID: String, cefr: CEFRLevel?, pos: PartOfSpeech, rank: Int?, headword: String)]
        rows = entries.map { entry in
            (
                stableID: entry.stableID,
                cefr: entry.cefr,
                pos: Self.albumPartOfSpeech(for: entry),
                rank: entry.frequencyRank,
                headword: entry.headword
            )
        }
        let albums: [Album]
        switch grouping {
        case .levelAndFamily, .tags:
            albums = Self.pageAlbums(entries: rows, languageCode: languageCode)
        }
        cache[languageCode] = albums
        return albums
    }

    public func album(containing entryStableID: String, languageCode: String) throws -> Album? {
        try albums(languageCode: languageCode).first { $0.entryStableIDs.contains(entryStableID) }
    }

    public func progress(of album: Album) throws -> AlbumProgress {
        let maturities = try maturityByEntry(languageCode: album.languageCode)
        return Self.progress(of: album, maturities: maturities)
    }

    /// Album count, completed albums, and shiny stickers across the language.
    public func summary(languageCode: String) throws -> (albums: Int, complete: Int, shiny: Int) {
        let albums = try albums(languageCode: languageCode)
        let maturities = try maturityByEntry(languageCode: languageCode)
        var complete = 0
        var shiny = 0
        for album in albums {
            let progress = Self.progress(of: album, maturities: maturities)
            if progress.isComplete { complete += 1 }
            shiny += progress.shinyCount
        }
        return (albums: albums.count, complete: complete, shiny: shiny)
    }

    /// Progress through every album of the language, in book order, from one card fetch.
    ///
    /// What the sticker book's contents page needs. Calling ``progress(of:)`` per album would
    /// fetch every card of the language once for each of ~275 pages.
    public func allProgress(languageCode: String) throws -> [AlbumProgress] {
        let albums = try albums(languageCode: languageCode)
        let maturities = try maturityByEntry(languageCode: languageCode)
        return albums.map { Self.progress(of: $0, maturities: maturities) }
    }

    /// Entries that only a Plus pack introduces: in a ``PlusCatalog/premiumDeckSlugs`` deck and
    /// in no free one. Albums made entirely of them wear a small "Plus" tag (§1.7) — they stay
    /// browsable either way.
    public func plusOnlyEntryIDs(languageCode: String) throws -> Set<String> {
        let decks = try context.fetch(
            FetchDescriptor<Deck>(predicate: #Predicate { $0.languageCode == languageCode })
        )
        var premium: Set<String> = []
        var free: Set<String> = []
        for deck in decks {
            let ids = deck.entries.map(\.stableID)
            if deck.requiresPlus {
                premium.formUnion(ids)
            } else {
                free.formUnion(ids)
            }
        }
        return premium.subtracting(free)
    }

    /// `true` when every word on the page comes only from a Plus pack.
    static func isPlusAlbum(_ album: Album, plusOnlyEntryIDs: Set<String>) -> Bool {
        !album.entryStableIDs.isEmpty && album.entryStableIDs.allSatisfy { plusOnlyEntryIDs.contains($0) }
    }

    public func invalidateCache() {
        cache.removeAll()
    }

    // MARK: - Pure parts

    /// Pages `entries` into albums: grouped by (level, family), ordered by frequency rank (words
    /// without one last) then headword, cut into pages of ``Album/pageSize``.
    ///
    /// Albums come out in level order, then family order, then page — the order the book shows.
    static func pageAlbums(
        entries: [(stableID: String, cefr: CEFRLevel?, pos: PartOfSpeech, rank: Int?, headword: String)],
        languageCode: String
    ) -> [Album] {
        struct Row {
            let stableID: String
            let rank: Int
            let headword: String
        }
        var groups: [String: [Row]] = [:]
        for entry in entries {
            let level = AlbumLevel(cefr: entry.cefr)
            let family = WordFamily(partOfSpeech: entry.pos)
            let key = "\(level.rawValue)|\(family.rawValue)"
            groups[key, default: []].append(
                Row(stableID: entry.stableID, rank: entry.rank ?? Int.max, headword: entry.headword)
            )
        }

        var albums: [Album] = []
        for level in AlbumLevel.allCases {
            for family in WordFamily.allCases {
                guard let rows = groups["\(level.rawValue)|\(family.rawValue)"], !rows.isEmpty else { continue }
                let ordered = rows.sorted { lhs, rhs in
                    if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                    if lhs.headword != rhs.headword { return lhs.headword < rhs.headword }
                    return lhs.stableID < rhs.stableID
                }
                var start = 0
                var page = 1
                while start < ordered.count {
                    let end = min(start + Album.pageSize, ordered.count)
                    albums.append(
                        Album(
                            languageCode: languageCode, level: level, family: family, page: page,
                            entryStableIDs: ordered[start..<end].map(\.stableID)
                        )
                    )
                    start = end
                    page += 1
                }
            }
        }
        return albums
    }

    /// The part of speech that decides a word's family.
    ///
    /// The primary sense's, read from the denormalised list (which the importer fills in sense
    /// order) so building the book does not fault in every sense. One correction: the seed packs
    /// say "phrasal verb", which ``PartOfSpeech`` has no case for and parses as `.other`. A
    /// multi-word `.other` is a phrasal verb in practice — exclamations and modals are single
    /// words — so it joins the verbs, as the plan asks.
    static func albumPartOfSpeech(for entry: Entry) -> PartOfSpeech {
        let primary = entry.partsOfSpeech.first ?? .other
        if primary == .other && entry.headword.contains(" ") { return .verb }
        return primary
    }

    static func progress(of album: Album, maturities: [String: CardMaturity]) -> AlbumProgress {
        let states = album.entryStableIDs.map { stableID -> StickerState in
            let maturity = maturities[stableID]
            return StickerState(maturity: maturity, isEnrolled: maturity != nil)
        }
        return AlbumProgress(album: album, states: states)
    }

    /// Least-advanced maturity per enrolled entry, from one card fetch.
    ///
    /// Same rule as ``Entry/maturity`` — a word is only as mature as its weakest card — but
    /// computed from the cards' own IDs (`"<stableID>#<direction>"`) so it costs one fetch
    /// instead of faulting the card relationship of every word in the book.
    private func maturityByEntry(languageCode: String) throws -> [String: CardMaturity] {
        let cards = try context.fetch(
            FetchDescriptor<Card>(predicate: #Predicate { $0.languageCode == languageCode })
        )
        var result: [String: CardMaturity] = [:]
        for card in cards {
            guard let hash = card.cardID.lastIndex(of: "#") else { continue }
            let stableID = String(card.cardID[..<hash])
            let maturity = card.maturity
            if let existing = result[stableID] {
                if Self.rank(maturity) < Self.rank(existing) { result[stableID] = maturity }
            } else {
                result[stableID] = maturity
            }
        }
        return result
    }

    private static func rank(_ maturity: CardMaturity) -> Int {
        switch maturity {
        case .new: return 0
        case .learning: return 1
        case .young: return 2
        case .mature: return 3
        }
    }
}
