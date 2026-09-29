import XCTest
import SwiftData
@testable import VocabLoop

@MainActor
final class PlusTests: XCTestCase {
    private func fixture() throws -> (ModelContext, UserAccount, StudyPreferences, Entry, Entry) {
        let context = try TestStore.makeContext()
        let account = try context.activeAccount()
        let preferences = try XCTUnwrap(account.preferences)
        preferences.newWordsPerDay = 10

        let free = Deck(slug: "en_core_a1_a2", name: "A1–A2", languageCode: "en", isBuiltIn: true)
        let premium = Deck(slug: "en_core_b1_b2", name: "B1–B2", languageCode: "en", isBuiltIn: true)
        context.insert(free)
        context.insert(premium)

        let freeWord = try TestStore.makeEntry(in: context, headword: "house", frequencyRank: 1)
        let premiumWord = try TestStore.makeEntry(in: context, headword: "negotiate", cefr: .b1, frequencyRank: 2)
        freeWord.decks.append(free)
        premiumWord.decks.append(premium)
        try context.save()
        return (context, account, preferences, freeWord, premiumWord)
    }

    func testPremiumPacksOfferNoNewWordsWithoutPlus() throws {
        let (context, account, preferences, freeWord, premiumWord) = try fixture()
        let service = DailyWordService(context: context, entitlements: Entitlements(defaults: nil))

        let next = try service.nextEntriesToIntroduce(for: account, preferences: preferences, limit: 10)
        XCTAssertTrue(next.contains { $0.stableID == freeWord.stableID }, "the free pack is always offered")
        XCTAssertFalse(next.contains { $0.stableID == premiumWord.stableID }, "a Plus pack waits for Plus")
    }

    func testPlusUnlocksPremiumPacks() throws {
        let (context, account, preferences, _, premiumWord) = try fixture()
        let entitlements = Entitlements(defaults: nil)
        entitlements.setPlus(true)
        let service = DailyWordService(context: context, entitlements: entitlements)

        let next = try service.nextEntriesToIntroduce(for: account, preferences: preferences, limit: 10)
        XCTAssertTrue(next.contains { $0.stableID == premiumWord.stableID })
    }

    /// A word in both a free and a Plus pack is free — the free pack offers it.
    func testAWordInAFreePackStaysFree() throws {
        let (context, account, preferences, _, premiumWord) = try fixture()
        let free = try XCTUnwrap(try context.deck(slug: "en_core_a1_a2"))
        premiumWord.decks.append(free)
        try context.save()

        let service = DailyWordService(context: context, entitlements: Entitlements(defaults: nil))
        let next = try service.nextEntriesToIntroduce(for: account, preferences: preferences, limit: 10)
        XCTAssertTrue(next.contains { $0.stableID == premiumWord.stableID })
    }

    func testUnlockIsRememberedAcrossLaunches() throws {
        let suite = "PlusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        Entitlements(defaults: defaults).setPlus(true)
        XCTAssertTrue(Entitlements(defaults: defaults).isPlus, "a cold start offline must not lock a paying user out")
    }

    func testOnlyTheBiggerPacksRequirePlus() {
        XCTAssertFalse(PlusCatalog.requiresPlus(deckSlug: "en_core_a1_a2"))
        XCTAssertFalse(PlusCatalog.requiresPlus(deckSlug: "fr_starter"))
        XCTAssertTrue(PlusCatalog.requiresPlus(deckSlug: "en_core_b1_b2"))
        XCTAssertTrue(PlusCatalog.requiresPlus(deckSlug: "en_core_c1"))
    }
}
