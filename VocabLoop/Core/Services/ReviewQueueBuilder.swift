import Foundation
import SwiftData

/// A card selected for study, paired with the interval each rating would produce.
///
/// The previews are computed once when the queue is built rather than when the card
/// is shown, so the rating bar has its labels ready and never has to compute during
/// the animation.
public struct QueueItem: Identifiable, Sendable {
    public let cardID: String
    public let entryStableID: String
    public let direction: CardDirection
    public let phase: LearningPhase

    public var id: String { cardID }

    public init(cardID: String, entryStableID: String, direction: CardDirection, phase: LearningPhase) {
        self.cardID = cardID
        self.entryStableID = entryStableID
        self.direction = direction
        self.phase = phase
    }
}

public struct ReviewQueue: Sendable {
    public var items: [QueueItem]
    /// Cards that are due but were left out by ``ReviewQueueBuilder/Options/maxCards``.
    /// Surfaced so the UI can say "60 of 214" instead of implying the backlog is gone.
    public var deferredCount: Int

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public static let empty = ReviewQueue(items: [], deferredCount: 0)
}

/// Chooses what to study, and in what order.
///
/// The ordering rules are the product decision that makes a session feel fair:
///
/// 1. **Intraday steps first.** A card the user saw two minutes ago and rated
///    `Again` must come back promptly, or the learning step is meaningless.
/// 2. **Then overdue reviews, most overdue first.** Cards decay while they wait, so
///    the most overdue are the ones nearest to being lost.
/// 3. **Then new cards**, in frequency order, so learners meet useful words first.
/// 4. **Sibling separation.** The recognition and production cards for one word are
///    kept apart in the queue — answering one immediately after the other tests
///    short-term memory, not recall.
///
/// The builder is deliberately not a `@MainActor` type and takes a `ModelContext`, so
/// the queue can be built off the main thread for a large collection.
public struct ReviewQueueBuilder: Sendable {
    public struct Options: Sendable {
        /// Session cap, so a large backlog presents as a session rather than a wall.
        public var maxCards: Int
        /// New cards this session may introduce.
        public var maxNewCards: Int
        /// Restrict to one language. `nil` studies everything.
        public var languageCode: String?
        /// Restrict to one deck's entries.
        public var deckSlug: String?
        /// Include cards not yet due, nearest-due first. Powers "Study ahead".
        public var includeAhead: Bool
        /// Minimum queue positions between two cards of the same entry.
        public var siblingSpacing: Int

        public init(
            maxCards: Int = 60,
            maxNewCards: Int = 8,
            languageCode: String? = nil,
            deckSlug: String? = nil,
            includeAhead: Bool = false,
            siblingSpacing: Int = 4
        ) {
            self.maxCards = maxCards
            self.maxNewCards = maxNewCards
            self.languageCode = languageCode
            self.deckSlug = deckSlug
            self.includeAhead = includeAhead
            self.siblingSpacing = siblingSpacing
        }
    }

    public init() {}

    public func build(in context: ModelContext, at now: Date, options: Options) throws -> ReviewQueue {
        let candidates = try fetchCandidates(in: context, options: options)

        var intraday: [Card] = []
        var due: [Card] = []
        var new: [Card] = []
        var ahead: [Card] = []

        for card in candidates {
            guard card.isAvailable else { continue }
            if card.phase == .new {
                new.append(card)
            } else if card.isDue(at: now) {
                if card.phase.isIntraday { intraday.append(card) } else { due.append(card) }
            } else if options.includeAhead {
                ahead.append(card)
            }
        }

        // Intraday: soonest-due first — these are time-critical by construction.
        intraday.sort { $0.due < $1.due }

        // Reviews: most overdue first, measured relative to the interval the card was
        // scheduled for. A 1-day card two days late has decayed far more than a
        // 200-day card two days late, and raw lateness would rank them the other way.
        due.sort { lhs, rhs in
            let a = overdueRatio(lhs, now: now)
            let b = overdueRatio(rhs, now: now)
            return a == b ? lhs.due < rhs.due : a > b
        }

        // New: most frequent words first, so early sessions teach useful vocabulary.
        new.sort { lhs, rhs in
            let a = lhs.entry?.frequencyRank ?? Int.max
            let b = rhs.entry?.frequencyRank ?? Int.max
            return a == b ? lhs.cardID < rhs.cardID : a < b
        }

        ahead.sort { $0.due < $1.due }

        let newAllowance = Array(new.prefix(max(0, options.maxNewCards)))
        var ordered = intraday + due + newAllowance
        let deferredDue = max(0, due.count - max(0, options.maxCards - intraday.count))

        if ordered.count < options.maxCards, options.includeAhead {
            ordered += ahead.prefix(options.maxCards - ordered.count)
        }

        ordered = Array(ordered.prefix(max(0, options.maxCards)))
        ordered = separateSiblings(ordered, minimumGap: options.siblingSpacing)

        return ReviewQueue(
            items: ordered.map {
                QueueItem(
                    cardID: $0.cardID,
                    entryStableID: $0.entry?.stableID ?? "",
                    direction: $0.direction,
                    phase: $0.phase
                )
            },
            deferredCount: deferredDue
        )
    }

    /// How far past its scheduled interval a card is, as a multiple of that interval.
    private func overdueRatio(_ card: Card, now: Date) -> Double {
        let lateDays = now.timeIntervalSince(card.due) / 86_400
        let scheduled = max(card.intervalDays, 0.01)
        return lateDays / scheduled
    }

    /// Fetch the candidate set.
    ///
    /// Filtering happens in Swift rather than in the predicate for the deck case:
    /// SwiftData cannot express "card whose entry belongs to deck X" reliably, and at
    /// our data volume a coarse fetch plus a filter is both fast enough and far easier
    /// to reason about than a predicate that silently returns the wrong rows.
    private func fetchCandidates(in context: ModelContext, options: Options) throws -> [Card] {
        var descriptor = FetchDescriptor<Card>(sortBy: [SortDescriptor(\.due)])
        if let languageCode = options.languageCode {
            descriptor.predicate = #Predicate { $0.languageCode == languageCode }
        }
        let cards = try context.fetch(descriptor)

        guard let deckSlug = options.deckSlug else { return cards }
        return cards.filter { card in
            card.entry?.decks.contains { $0.slug == deckSlug } ?? false
        }
    }

    /// Push cards sharing an entry apart, preserving relative order otherwise.
    ///
    /// Greedy single pass: walk the queue, and whenever the next card's sibling
    /// appeared within `minimumGap` positions, look ahead for the first card that
    /// doesn't collide and take that instead. Falls back to the original card when
    /// nothing else fits, so the queue never loses an item or loops.
    func separateSiblings(_ cards: [Card], minimumGap: Int) -> [Card] {
        guard minimumGap > 0, cards.count > 1 else { return cards }

        var remaining = cards
        var result: [Card] = []
        result.reserveCapacity(cards.count)
        var lastPosition: [String: Int] = [:]

        while !remaining.isEmpty {
            let position = result.count
            var chosenIndex = 0
            for (index, card) in remaining.enumerated() {
                let key = card.entry?.stableID ?? card.cardID
                if let last = lastPosition[key], position - last < minimumGap {
                    continue
                }
                chosenIndex = index
                break
            }
            let card = remaining.remove(at: chosenIndex)
            lastPosition[card.entry?.stableID ?? card.cardID] = position
            result.append(card)
        }
        return result
    }
}
