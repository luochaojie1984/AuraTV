import XCTest
@testable import AppPreferences

final class AppSettingsTests: XCTestCase {
    func testDefaultSettings() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.shortSeekSeconds, 10)
        XCTAssertEqual(settings.shortPressSeekBehavior, .multiStageShuttle)
        XCTAssertEqual(settings.longPressSeekMode, .mxLiveKeyframeScrub)
        XCTAssertTrue(settings.enableTouchpadScrub)
        XCTAssertEqual(settings.readAheadCacheLimitMB, 96)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(decoded, settings)
    }

    func testLegacyV1SettingsJSONDecodesWithMXShuttleDefaults() throws {
        let legacyJSON = """
        {
            "shortSeekSeconds": 15,
            "longPressSeekMode": "mxLiveKeyframeScrub",
            "readAheadCacheLimitMB": 128
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.shortSeekSeconds, 15)
        XCTAssertEqual(decoded.shortPressSeekBehavior, .multiStageShuttle)
        XCTAssertTrue(decoded.enableTouchpadScrub)
        XCTAssertEqual(decoded.readAheadCacheLimitMB, 128)
    }
}
