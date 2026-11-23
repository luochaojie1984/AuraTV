import XCTest
@testable import SubtitleKit

final class SubtitleStyleConfigTests: XCTestCase {
    func testSubtitleStyleDefaultsAndCodable() throws {
        let config = SubtitleStyleConfig()
        XCTAssertEqual(config.fontSize, 56)
        XCTAssertEqual(config.bottomOffsetRatio, 0.06, accuracy: 0.0001)
        XCTAssertEqual(config.textColorHex, "#FFF5DC")
        XCTAssertFalse(config.overrideASSStyles)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SubtitleStyleConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }
}
