import XCTest
@testable import AppPreferences

final class AppSettingsTests: XCTestCase {
    func testDefaultSettings() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.shortSeekSeconds, 10)
        XCTAssertEqual(settings.longPressSeekMode, .mxLiveKeyframeScrub)
        XCTAssertEqual(settings.readAheadCacheLimitMB, 96)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(decoded, settings)
    }
}
