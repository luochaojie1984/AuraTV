import XCTest
@testable import SubtitleKit

final class SubtitleKitComprehensiveTests: XCTestCase {
    // MARK: - Encoding Detection Tests

    func testUTF8WithBOMStripping() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("1\r\n00:00:01,000 --> 00:00:03,000\r\n你好，苹果电视！\r\n".utf8))
        let result = SubtitleEncodingDetector.decode(data)
        XCTAssertEqual(result.encoding, .utf8BOM)
        XCTAssertTrue(result.text.contains("你好，苹果电视！"))
        XCTAssertFalse(result.text.contains("\r"))
    }

    func testUTF16LEWithBOM() {
        let original = "1\n00:00:01,000 --> 00:00:02,000\n中文字幕测试"
        var data = Data([0xFF, 0xFE])
        data.append(original.data(using: .utf16LittleEndian)!)
        let result = SubtitleEncodingDetector.decode(data)
        XCTAssertEqual(result.encoding, .utf16LE)
        XCTAssertEqual(result.text, original)
    }

    func testGB18030ChineseDecodingNoMojibake() {
        // Exact GBK/GB18030 bytes for: "1\n00:00:01,000 --> 00:00:04,000\n你好世界，中文字幕测试！"
        // 你=C4 E3, 好=BA C3, 世=CA C0, 界=BD E7, ，=A3 AC, 中=D6 D0, 文=CE C4, 字=D7 D6, 幕=C4 BB, 测=B2 E2, 试=CA D4, ！=A3 A1
        var data = Data("1\n00:00:01,000 --> 00:00:04,000\n".utf8)
        data.append(contentsOf: [
            0xC4, 0xE3, 0xBA, 0xC3, 0xCA, 0xC0, 0xBD, 0xE7,
            0xA3, 0xAC, 0xD6, 0xD0, 0xCE, 0xC4, 0xD7, 0xD6,
            0xC4, 0xBB, 0xB2, 0xE2, 0xCA, 0xD4, 0xA3, 0xA1
        ])
        let result = SubtitleEncodingDetector.decode(data)
        XCTAssertEqual(result.encoding, .gb18030)
        XCTAssertTrue(result.text.contains("你好世界，中文字幕测试！"), "Decoded text was: \(result.text)")
    }

    func testBig5TraditionalChineseDecoding() {
        // Exact Big5 bytes for: "歡迎觀看高清電影"
        // 歡=C5 77, 迎=AA EF, 觀=C6 5B, 看=AC DD, 高=B0 AA, 清=B2 4D, 電=B9 71, 影=BC 76
        var data = Data("1\n00:00:01,000 --> 00:00:04,000\n".utf8)
        data.append(contentsOf: [
            0xC5, 0x77, 0xAA, 0xEF, 0xC6, 0x5B, 0xAC, 0xDD,
            0xB0, 0xAA, 0xB2, 0x4D, 0xB9, 0x71, 0xBC, 0x76
        ])
        let result = SubtitleEncodingDetector.decode(data)
        XCTAssertTrue(result.text.contains("歡迎觀看高清電影"), "Decoded: \(result.text) (\(result.encoding))")
    }

    // MARK: - Auto-Matcher Tests

    func testSubtitleMatcherPrioritizesSimplifiedChineseAndExactStem() {
        let sameDir = [
            SubtitleSourceFile(name: "Dune.2024.2160p.DV.eng.srt", path: "/Movies/Dune.2024.2160p.DV.eng.srt"),
            SubtitleSourceFile(name: "Dune.2024.2160p.DV.cht.srt", path: "/Movies/Dune.2024.2160p.DV.cht.srt"),
            SubtitleSourceFile(name: "Dune.2024.2160p.DV.chs&eng.ass", path: "/Movies/Dune.2024.2160p.DV.chs&eng.ass"),
            SubtitleSourceFile(name: "Dune.2024.2160p.DV.zh-Hans.ass", path: "/Movies/Dune.2024.2160p.DV.zh-Hans.ass"),
            SubtitleSourceFile(name: "Unrelated.Movie.chs.srt", path: "/Movies/Unrelated.Movie.chs.srt"),
        ]

        let ranked = SubtitleMatcher.match(videoFileName: "Dune.2024.2160p.DV.mkv", sameDirectoryFiles: sameDir)
        XCTAssertEqual(ranked.count, 4, "Unrelated movie subtitle must be excluded")
        XCTAssertEqual(ranked[0].name, "Dune.2024.2160p.DV.zh-Hans.ass")
        XCTAssertEqual(ranked[0].detectedLanguageLabel, "简体中文")
        XCTAssertEqual(ranked[1].name, "Dune.2024.2160p.DV.chs&eng.ass")
        XCTAssertEqual(ranked[1].detectedLanguageLabel, "中英双语")
        XCTAssertEqual(ranked[2].name, "Dune.2024.2160p.DV.cht.srt")
        XCTAssertEqual(ranked[3].name, "Dune.2024.2160p.DV.eng.srt")
    }

    func testSubtitleMatcherEpisodeNumberAndSubfolderDiscovery() {
        let subFiles = [
            SubtitleSourceFile(name: "Show.S01E02.WebDL.chs.srt", path: "/TV/Subs/Show.S01E02.WebDL.chs.srt", isInSubfolder: true),
            SubtitleSourceFile(name: "Show.S01E03.WebDL.chs.srt", path: "/TV/Subs/Show.S01E03.WebDL.chs.srt", isInSubfolder: true),
        ]
        let ranked = SubtitleMatcher.match(
            videoFileName: "My.Favorite.Show.S01E02.2160p.HEVC.mkv",
            sameDirectoryFiles: [],
            subfolderFiles: subFiles
        )
        XCTAssertEqual(ranked.first?.name, "Show.S01E02.WebDL.chs.srt")
    }

    // MARK: - Parser & Delay Sync Lookup Tests

    func testSRTParsingAndDelaySyncLookup() {
        let srt = """
        1
        00:00:02,500 --> 00:00:05,000
        <i>第一句台词</i>

        2
        00:01:10,000 --> 00:01:13,500
        第二句台词
        换行内容
        """
        let track = SubtitleParser.parse(text: srt, fileExtension: "srt")
        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.cues[0].text, "第一句台词")
        XCTAssertEqual(track.cues[1].text, "第二句台词\n换行内容")

        XCTAssertEqual(track.activeCues(at: 3.0).first?.text, "第一句台词")
        XCTAssertTrue(track.activeCues(at: 1.0).isEmpty)

        // +1.5s delay shifts cue [2.5..5.0] to appear at playbackTime [4.0..6.5]
        XCTAssertTrue(track.activeCues(at: 3.0, delaySeconds: 1.5).isEmpty)
        XCTAssertEqual(track.activeCues(at: 5.5, delaySeconds: 1.5).first?.text, "第一句台词")
    }

    func testASSParsingStripsOverrideTagsAndPreservesRawASS() {
        let ass = """
        [Script Info]
        Title: Test Anime

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:10.50,0:00:14.25,Default,,0,0,0,,{\\pos(960,980)\\fs48\\c&H00FFFF&}你好，新世界\\NHello, New World
        """
        let track = SubtitleParser.parse(text: ass, fileExtension: "ass")
        XCTAssertEqual(track.format, "ass")
        XCTAssertNotNil(track.rawASSContent)
        XCTAssertEqual(track.cues.count, 1)
        XCTAssertEqual(track.cues[0].startTime, 10.50, accuracy: 0.01)
        XCTAssertEqual(track.cues[0].endTime, 14.25, accuracy: 0.01)
        XCTAssertEqual(track.cues[0].text, "你好，新世界\nHello, New World")
        XCTAssertEqual(track.activeCues(at: 12.0).first?.text, "你好，新世界\nHello, New World")
    }

    func testWebVTTParsing() {
        let vtt = """
        WEBVTT

        00:05.000 --> 00:08.500 align:center
        Welcome to AuraTV
        """
        let track = SubtitleParser.parse(text: vtt, fileExtension: "vtt")
        XCTAssertEqual(track.cues.count, 1)
        XCTAssertEqual(track.cues[0].startTime, 5.0, accuracy: 0.01)
        XCTAssertEqual(track.cues[0].text, "Welcome to AuraTV")
    }
}
