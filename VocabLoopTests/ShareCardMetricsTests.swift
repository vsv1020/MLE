import XCTest
@testable import VocabLoop

/// Every share image is 4:5 portrait, 1080×1350 (sharing plan §2).
final class ShareCardMetricsTests: XCTestCase {
    func testPointSizeIs360By450() {
        XCTAssertEqual(ShareCardMetrics.pointSize.width, 360)
        XCTAssertEqual(ShareCardMetrics.pointSize.height, 450)
        XCTAssertEqual(ShareCardMetrics.scale, 3)
    }

    func testPixelSizeIs1080By1350() {
        XCTAssertEqual(ShareCardMetrics.pixelSize.width, 1080)
        XCTAssertEqual(ShareCardMetrics.pixelSize.height, 1350)
    }

    func testRecapAliasIsStill1080By1350() {
        XCTAssertEqual(RecapShareMetrics.pixelSize.width, 1080)
        XCTAssertEqual(RecapShareMetrics.pixelSize.height, 1350)
    }
}
