import XCTest
@testable import WhisperCore

final class WhisperCoreTests: XCTestCase {
    func testWhisperKitLinks() {
        XCTAssertEqual(WhisperCoreInfo.whisperKitAvailable(), "WhisperKit")
    }
}
