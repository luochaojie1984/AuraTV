import XCTest
@testable import LocalStreamProxy

final class LocalStreamProxyTests: XCTestCase {
    func testPhase0PlaceholderInfo() {
        let info = LocalStreamProxyInfo()
        XCTAssertEqual(info.version, "0.1.0-phase0")
    }
}
