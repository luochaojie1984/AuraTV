import XCTest
@testable import SubtitleKit
import NetworkVFS
import LocalStreamProxy
import AppPreferences

final class MultilingualFilenameEdgeCaseTests: XCTestCase {
    func testVeryLongJapaneseChineseSymbolFilenameMatchingAndNFCNFD() {
        // Long realistic anime/movie title with Japanese, Chinese, brackets, #, %, +, ・, full-width symbols
        let longVideoNFC = "[字幕組&RAW] 劇場版 鬼滅の刃・無限城編 #01 (2025) 【2160p・HEVC・100%無損・HDR10+DV】 [FLAC+TrueHD7.1] 超长中文副标题测试文件名.mkv"
        // Simulate macOS/NAS NFD decomposed Japanese characters in subtitle filename (が -> か + \u{3099})
        let longSubNFD = "[字幕組&RAW] 劇場版 鬼滅の刃・無限城編 #01 (2025) 【2160p・HEVC・100%無損・HDR10+DV】 [FLAC+TrueHD7.1] 超长中文副标题测试文件名.zh-Hans.ass"
            .decomposedStringWithCanonicalMapping

        let ranked = SubtitleMatcher.match(
            videoFileName: longVideoNFC,
            sameDirectoryFiles: [
                SubtitleSourceFile(name: longSubNFD, path: "/动画/超长目录【日本語・中文】#1/\(longSubNFD)")
            ]
        )
        XCTAssertEqual(ranked.count, 1)
        XCTAssertGreaterThanOrEqual(ranked[0].score, 130)
        XCTAssertEqual(ranked[0].detectedLanguageLabel, "简体中文")
    }

    func testJapaneseEpisodeMatchingDaiWa() {
        let video = "【推しの子】 第07話 「バズ」 (BD 1920x1080 HEVC 10bit).mkv"
        let sub = "[ANi] 推しの子 - 第7集 [简体中文].ass"
        let ranked = SubtitleMatcher.match(
            videoFileName: video,
            sameDirectoryFiles: [SubtitleSourceFile(name: sub, path: "/Anime/\(sub)")]
        )
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].name, sub)
    }

    func testLocalProxyUsesShortASCIIURLForLongSymbolCJKFilename() throws {
        final class TinyStream: VFSRandomAccessStream {
            var totalSize: Int64 { 16 }
            func read(offset: Int64, length: Int) async throws -> Data { Data(repeating: 0x41, count: min(length, 16)) }
            func close() async {}
        }

        let proxy = LocalHTTPStreamProxy()
        try proxy.start()
        defer { proxy.stop() }

        let trickyName = "進撃の巨人 #12? What%20[100%+HDR] 【超长中文&日本語ファイル名テスト】.mkv"
        let (token, url) = try proxy.register(stream: TinyStream(), fileName: trickyName)
        defer { proxy.unregister(token: token) }

        // URL must be pure short ASCII without raw '#', '?', '%' or 600-char percent encoding!
        XCTAssertTrue(url.absoluteString.hasSuffix("/stream/\(token).mkv"))
        XCTAssertLessThan(url.absoluteString.count, 100)
    }

    func testPlaybackHistoryPreservesLongMultilingualPathsWithSymbols() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraTV-CJK-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PlaybackHistoryStore(storageDirectory: tempDir)
        let srcID = UUID()
        let longPath = "/2025新番【日本語・中文】#1 (100%)/[Sub&Team] 葬送のフリーレン 第01話？「冒険の終わり」 [4K HDR10+].mkv"

        try await store.recordProgress(PlaybackHistoryRecord(
            sourceID: srcID,
            filePath: longPath,
            fileName: "[Sub&Team] 葬送のフリーレン 第01話？「冒険の終わり」 [4K HDR10+].mkv",
            lastPositionSeconds: 450,
            durationSeconds: 1440
        ))

        let loaded = try await PlaybackHistoryStore(storageDirectory: tempDir).history(sourceID: srcID, filePath: longPath)
        XCTAssertEqual(loaded?.filePath, longPath)
        XCTAssertEqual(loaded?.lastPositionSeconds, 450)
    }
}
