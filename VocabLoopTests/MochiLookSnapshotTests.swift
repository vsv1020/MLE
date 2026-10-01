import XCTest
@testable import VocabLoop

/// Mochi rebuilt from the raw values in the widget snapshot and the Live Activity. A file from a
/// newer build may name a colour or an item this one does not know; that must draw a plainer
/// Mochi, never no Mochi.
final class MochiLookSnapshotTests: XCTestCase {
    private func snapshot(level: Int = 4, color: String, accessories: [String]) -> WidgetSnapshot {
        WidgetSnapshot(
            dueNow: 0, reviewsToday: 0, dailyGoal: 30, streak: 0, studiedToday: false,
            mochiLevel: level, candy: 0, bodyColor: color, accessories: accessories,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testKnownValuesRoundTrip() {
        let look = MochiLook(snapshot: snapshot(level: 12, color: "matcha", accessories: ["partyHat", "redScarf"]))
        XCTAssertEqual(look.stage, .teen)
        XCTAssertEqual(look.color, .matcha)
        XCTAssertEqual(look.accessories, [.partyHat, .redScarf])
    }

    func testUnknownColourDegradesToVanilla() {
        let look = MochiLook(snapshot: snapshot(color: "dragonfruit", accessories: []))
        XCTAssertEqual(look.color, .vanilla)
    }

    func testUnknownAccessoriesAreDropped() {
        let look = MochiLook(snapshot: snapshot(color: "mint", accessories: ["jetpack", "bow", ""]))
        XCTAssertEqual(look.color, .mint)
        XCTAssertEqual(look.accessories, [.bow])
    }

    func testOneItemPerSlot() {
        let look = MochiLook(snapshot: snapshot(color: "vanilla", accessories: ["crown", "partyHat", "cape"]))
        XCTAssertEqual(look.accessories, [.crown, .cape])
    }

    func testStageFollowsLevelLikeRewardEngine() {
        for level in [1, 4, 5, 9, 10, 14, 15, 30] {
            XCTAssertEqual(MochiStage(level: level), RewardEngine.stage(forLevel: level), "level \(level)")
            XCTAssertEqual(MochiLook(snapshot: snapshot(level: level, color: "vanilla", accessories: [])).stage,
                           MochiStage(level: level))
        }
    }

    func testActivityAttributesDrawTheSameMochi() {
        let attributes = StudyActivityAttributes(
            mochiLevel: 6, bodyColor: "unknown", accessories: ["bow", "nope"], dailyGoal: 30,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(attributes.look, MochiLook(stage: .kid, color: .vanilla, accessories: [.bow]))
    }
}
