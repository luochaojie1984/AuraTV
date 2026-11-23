import XCTest
@testable import AppPreferences
import NetworkVFS
import SubtitleKit

final class AppPreferencesStoresTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraTVTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testMediaSourceStoreCRUDAndPersistence() async throws {
        let store = MediaSourceStore(storageDirectory: tempDir)
        let smb = MediaSourceConfig(
            displayName: "Home NAS",
            protocolType: .smb,
            host: "192.168.5.229",
            basePath: "/AV",
            username: "guest"
        )
        try await store.upsert(smb)

        // Reload from fresh store instance to verify disk persistence
        let reloaded = MediaSourceStore(storageDirectory: tempDir)
        let loaded = try await reloaded.allSources()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].displayName, "Home NAS")
        XCTAssertEqual(loaded[0].host, "192.168.5.229")

        try await reloaded.delete(id: smb.id)
        let remaining = try await reloaded.allSources(); XCTAssertTrue(remaining.isEmpty)
    }

    func testPlaybackHistoryContinueWatchingFilteringAndOrdering() async throws {
        let store = PlaybackHistoryStore(storageDirectory: tempDir)
        let srcID = UUID()
        let now = Date()

        // 1. Mid-way movie (older) -> should appear 2nd
        try await store.recordProgress(PlaybackHistoryRecord(
            sourceID: srcID,
            filePath: "/Movies/A.mkv",
            fileName: "A.mkv",
            lastPositionSeconds: 1200,
            durationSeconds: 7200,
            lastPlayedAt: now.addingTimeInterval(-3600)
        ))

        // 2. Recently watched movie (newer) -> should appear 1st
        try await store.recordProgress(PlaybackHistoryRecord(
            sourceID: srcID,
            filePath: "/Movies/B.mkv",
            fileName: "B.mkv",
            lastPositionSeconds: 600,
            durationSeconds: 3600,
            lastPlayedAt: now,
            selectedSubtitlePath: "/Movies/B.chs.ass"
        ))

        // 3. Finished movie (96%) -> excluded from continueWatching
        try await store.recordProgress(PlaybackHistoryRecord(
            sourceID: srcID,
            filePath: "/Movies/Finished.mkv",
            fileName: "Finished.mkv",
            lastPositionSeconds: 960,
            durationSeconds: 1000,
            lastPlayedAt: now.addingTimeInterval(10)
        ))

        // 4. Barely started (5s) -> excluded from continueWatching
        try await store.recordProgress(PlaybackHistoryRecord(
            sourceID: srcID,
            filePath: "/Movies/Brief.mkv",
            fileName: "Brief.mkv",
            lastPositionSeconds: 5,
            durationSeconds: 1000,
            lastPlayedAt: now.addingTimeInterval(20)
        ))

        let reloaded = PlaybackHistoryStore(storageDirectory: tempDir)
        let list = try await reloaded.continueWatching()
        XCTAssertEqual(list.map(\.fileName), ["B.mkv", "A.mkv"])
        XCTAssertEqual(list[0].selectedSubtitlePath, "/Movies/B.chs.ass")
    }

    func testAppSettingsStoreClampsCacheAndPersistsSubtitleStyle() async throws {
        let store = AppSettingsStore(storageDirectory: tempDir)
        var s = try await store.load()
        s.readAheadCacheLimitMB = 512 // exceeds 192 MB Jetsam safety cap
        try await store.save(s)

        let updatedStyle = try await store.updateSubtitleStyle { style in
            style.fontSize = 68
            style.bottomOffsetRatio = 0.14
            style.textColorHex = SubtitleColorPreset.cinemaYellow.rawValue
            style.textOpacity = 0.78
            style.overrideASSStyles = true
        }
        XCTAssertEqual(updatedStyle.fontSize, 68)

        let reloaded = try await AppSettingsStore(storageDirectory: tempDir).load()
        XCTAssertEqual(reloaded.readAheadCacheLimitMB, 192, "Cache limit must clamp at 192 MB for tvOS Jetsam safety")
        XCTAssertEqual(reloaded.subtitleStyle.textColorHex, "#FFD700")
        XCTAssertEqual(reloaded.subtitleStyle.bottomOffsetRatio, 0.14, accuracy: 0.0001)
        XCTAssertTrue(reloaded.subtitleStyle.overrideASSStyles)
    }

    func testWebDAVBackupPayloadRoundTrip() throws {
        let src = MediaSourceConfig(displayName: "DAV", protocolType: .webdav, host: "dav.local", useTLS: true)
        let hist = PlaybackHistoryRecord(
            sourceID: src.id,
            filePath: "/film.mkv",
            fileName: "film.mkv",
            lastPositionSeconds: 320,
            durationSeconds: 5400,
            lastPlayedAt: Date(timeIntervalSince1970: 1_764_000_000)
        )
        let payload = AuraTVBackupPayload(
            exportedAt: Date(timeIntervalSince1970: 1_764_000_100),
            sources: [src],
            history: [hist],
            settings: AppSettings()
        )
        let data = try WebDAVBackupService.encodeBackup(payload)
        let decoded = try WebDAVBackupService.decodeBackup(data)
        XCTAssertEqual(decoded, payload)
    }
}
