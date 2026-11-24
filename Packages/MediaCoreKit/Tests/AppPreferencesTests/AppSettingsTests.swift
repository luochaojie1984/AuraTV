import XCTest
@testable import AppPreferences

final class AppSettingsTests: XCTestCase {
    func testDefaultSettings() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.shortSeekSeconds, 10)
        XCTAssertEqual(settings.shortPressSeekBehavior, .fixedStepJump)
        XCTAssertEqual(settings.longPressSeekMode, .mxLiveKeyframeScrub)
        XCTAssertEqual(settings.longPressSpeedProfile, .mxStandard)
        XCTAssertTrue(settings.enableTouchpadScrub)
        XCTAssertEqual(settings.scrubBarColorHex, ScrubBarColorPreset.skyBlue.rawValue)
        XCTAssertEqual(settings.scrubBarOpacity, 0.65, accuracy: 0.001)
        XCTAssertEqual(settings.scrubBarHeight, 5.0, accuracy: 0.001)
        XCTAssertTrue(settings.showScrubTimeText)
        XCTAssertTrue(settings.enableResumePlayback)
        XCTAssertTrue(settings.enableUISoundEffects)
        XCTAssertEqual(settings.readAheadCacheLimitMB, 96)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(decoded, settings)
    }

    func testLegacyV1SettingsJSONDecodesWithMXDefaults() throws {
        let legacyJSON = """
        {
            "shortSeekSeconds": 15,
            "longPressSeekMode": "mxLiveKeyframeScrub",
            "readAheadCacheLimitMB": 128
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.shortSeekSeconds, 15)
        XCTAssertEqual(decoded.shortPressSeekBehavior, .fixedStepJump)
        XCTAssertEqual(decoded.longPressSpeedProfile, .mxStandard)
        XCTAssertTrue(decoded.enableTouchpadScrub)
        XCTAssertTrue(decoded.enableResumePlayback)
        XCTAssertTrue(decoded.enableUISoundEffects)
        XCTAssertEqual(decoded.scrubBarColorHex, "#38BDF8")
        XCTAssertEqual(decoded.readAheadCacheLimitMB, 128)
    }
}
