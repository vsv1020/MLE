import XCTest
@testable import VocabLoop

/// The file the widget reads instead of the SwiftData store.
final class WidgetSnapshotTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appending(path: "widget-tests-\(UUID().uuidString)")
            .appending(path: "widget-snapshot.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeSnapshot(candy: Int = 1_240) -> WidgetSnapshot {
        WidgetSnapshot(
            dueNow: 12, reviewsToday: 18, dailyGoal: 30, streak: 6, studiedToday: true,
            mochiLevel: RewardEngine.level(forCandy: candy), candy: candy,
            bodyColor: MochiBodyColor.matcha.rawValue,
            accessories: [MochiAccessory.partyHat.rawValue, MochiAccessory.redScarf.rawValue],
            updatedAt: Date(timeIntervalSince1970: 1_700_042_400)
        )
    }

    func testSnapshotRoundTripsThroughTheFile() {
        let writer = WidgetSnapshotWriter(url: url)
        let snapshot = makeSnapshot()
        writer.write(snapshot)
        XCTAssertEqual(writer.read(), snapshot)
    }

    func testLaterWriteReplacesTheEarlierOne() {
        let writer = WidgetSnapshotWriter(url: url)
        writer.write(makeSnapshot(candy: 10))
        writer.write(makeSnapshot(candy: 500))
        XCTAssertEqual(writer.read()?.candy, 500)
        XCTAssertEqual(writer.read()?.mochiLevel, 5)
    }

    func testMissingOrCorruptFileReadsAsNil() throws {
        let writer = WidgetSnapshotWriter(url: url)
        XCTAssertNil(writer.read())

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(writer.read())
    }

    /// A file written by 1.0.7 has no `dayEndsAt` or `dueTomorrow`. It must still decode — the
    /// widget's first read after the update is of exactly that file.
    func testA107FileWithoutTheNewKeysStillDecodes() throws {
        let json = """
        {"accessories":["partyHat"],"bodyColor":"matcha","candy":640,"dailyGoal":30,"dueNow":12,\
        "mochiLevel":4,"reviewsToday":8,"streak":7,"studiedToday":true,"updatedAt":1700042400}
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: url)

        let snapshot = try XCTUnwrap(WidgetSnapshotWriter(url: url).read())
        XCTAssertEqual(snapshot.dueNow, 12)
        XCTAssertEqual(snapshot.streak, 7)
        XCTAssertEqual(snapshot.updatedAt, Date(timeIntervalSince1970: 1_700_042_400))
        XCTAssertNil(snapshot.dayEndsAt)
        XCTAssertNil(snapshot.dueTomorrow)
    }

    func testNewFieldsRoundTrip() {
        let writer = WidgetSnapshotWriter(url: url)
        var snapshot = makeSnapshot()
        snapshot.dayEndsAt = Date(timeIntervalSince1970: 1_700_078_400)
        snapshot.dueTomorrow = 21
        writer.write(snapshot)
        let read = writer.read()
        XCTAssertEqual(read, snapshot)
        XCTAssertEqual(read?.dayEndsAt, Date(timeIntervalSince1970: 1_700_078_400))
        XCTAssertEqual(read?.dueTomorrow, 21)
    }

    func testSharedStorageNamesTheSnapshotFile() {
        XCTAssertEqual(SharedStorage.appGroupID, "group.com.vocabloop.app")
        XCTAssertEqual(SharedStorage.widgetSnapshotURL.lastPathComponent, "widget-snapshot.json")
    }
}
