import XCTest
import SwiftData
@testable import VocabLoop

/// ``AppDependencies/switchLanguage(to:)`` — the one switch behind Settings ▸ 语言 and the
/// language chip on the study screen.
@MainActor
final class LanguageSwitchTests: XCTestCase {
    private var dependencies: AppDependencies!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let container = try PersistenceController.makeInMemoryContainer()
        dependencies = AppDependencies(container: container)
        _ = try dependencies.context.activeAccount()
    }

    override func tearDown() {
        dependencies = nil
        super.tearDown()
    }

    func testSwitchingActivatesTheLanguageAndKeepsTheOldOneInstalled() async throws {
        let preferences = try XCTUnwrap(dependencies.preferences)
        XCTAssertEqual(preferences.activeLanguage, .english)

        await dependencies.switchLanguage(to: .french)

        XCTAssertEqual(preferences.activeLanguageCode, "fr")
        XCTAssertTrue(
            preferences.installedLanguageCodes.contains("fr"),
            "the packs are installed as part of the switch, so the dictionary is never empty"
        )
        XCTAssertTrue(
            preferences.installedLanguageCodes.contains("en"),
            "switching away keeps English installed — its progress is kept, not reset"
        )
    }

    func testSwitchingToTheActiveLanguageChangesNothing() async throws {
        let preferences = try XCTUnwrap(dependencies.preferences)
        let stamp = Date(timeIntervalSince1970: 1_700_042_400)
        preferences.touch(stamp)

        await dependencies.switchLanguage(to: .english)

        XCTAssertEqual(preferences.activeLanguageCode, "en")
        XCTAssertEqual(preferences.installedLanguageCodes, ["en"])
        XCTAssertEqual(preferences.updatedAt, stamp, "a no-op switch must not queue a sync")
    }
}
