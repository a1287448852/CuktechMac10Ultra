import XCTest
@testable import CuktechCore

final class SmokeTests: XCTestCase {
    func testBuildInfo() {
        XCTAssertFalse(BuildInfo.version.isEmpty)
        XCTAssertEqual(BuildInfo.channel, "mac-glass")
    }
}
