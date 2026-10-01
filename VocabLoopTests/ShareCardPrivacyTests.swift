import SwiftData
import XCTest
@testable import VocabLoop

/// Nothing on a share card identifies the child (sharing plan §4, §5).
@MainActor
final class ShareCardPrivacyTests: XCTestCase {
    func testWordCardRefusesUserCreatedEntries() throws {
        let context = try TestStore.makeContext()
        let entry = try TestStore.makeEntry(in: context, headword: "mysecretword")
        entry.isUserCreated = true
        try context.save()
        XCTAssertNil(WordCard.make(from: entry))
    }

    func testWordCardRefusesAnEntryWithoutSenses() throws {
        let context = try TestStore.makeContext()
        let entry = Entry(
            stableID: Entry.makeStableID(language: "en", headword: "empty"),
            languageCode: "en",
            headword: "empty"
        )
        context.insert(entry)
        try context.save()
        XCTAssertNil(WordCard.make(from: entry))
    }

    func testWordCardCopiesDictionaryContentOnly() throws {
        let context = try TestStore.makeContext()
        let entry = try TestStore.makeEntry(in: context, headword: "window", definition: "an opening in a wall")
        entry.senses.first?.examples = [ExampleSentence(text: "Open the window, please.")]
        try context.save()

        let card = try XCTUnwrap(WordCard.make(from: entry))
        XCTAssertEqual(card.headword, "window")
        XCTAssertEqual(card.definition, "an opening in a wall")
        XCTAssertEqual(card.example, "Open the window, please.")
        XCTAssertEqual(card.languageCode, "en")
    }

    func testNoPayloadCarriesPersonalData() {
        let forbidden = ["displayname", "email", "userid", "accountid"]
        XCTAssertEqual(ShareCardFixtures.all.count, ShareCard.Kind.allCases.count)
        for card in ShareCardFixtures.all {
            let labels = Self.propertyNames(of: card)
            XCTAssertFalse(labels.isEmpty, "\(card.kind) was not inspected")
            for label in labels {
                let lowered = label.lowercased()
                for word in forbidden {
                    XCTAssertFalse(lowered.contains(word), "\(card.kind) carries “\(label)”")
                }
            }
        }
    }

    /// Every stored property name in a payload, recursively (MochiLook, recap words…).
    private static func propertyNames(of value: Any, depth: Int = 0) -> [String] {
        guard depth < 6 else { return [] }
        var names: [String] = []
        for child in Mirror(reflecting: value).children {
            if let label = child.label { names.append(label) }
            names += propertyNames(of: child.value, depth: depth + 1)
        }
        return names
    }
}
