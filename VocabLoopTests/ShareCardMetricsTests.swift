import XCTest
@testable import VocabLoop

/// Every share image is a 3:4 portrait poster, 1080×1440 (sharing plan §2).
final class ShareCardMetricsTests: XCTestCase {
    func testPointSizeIs360By480() {
        XCTAssertEqual(ShareCardMetrics.pointSize.width, 360)
        XCTAssertEqual(ShareCardMetrics.pointSize.height, 480)
        XCTAssertEqual(ShareCardMetrics.scale, 3)
    }

    func testPixelSizeIs1080By1440() {
        XCTAssertEqual(ShareCardMetrics.pixelSize.width, 1080)
        XCTAssertEqual(ShareCardMetrics.pixelSize.height, 1440)
        XCTAssertEqual(ShareCardMetrics.pixelSize.width * 4, ShareCardMetrics.pixelSize.height * 3)
    }

    func testRecapAliasIsAlso1080By1440() {
        XCTAssertEqual(RecapShareMetrics.pixelSize.width, 1080)
        XCTAssertEqual(RecapShareMetrics.pixelSize.height, 1440)
    }
}
