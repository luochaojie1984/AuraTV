import Foundation
import SubtitleKit

public enum LongPressSeekMode: String, CaseIterable, Codable, Sendable {
    case mxLiveKeyframeScrub
    case continuousFastPlay
}

public enum ShortPressSeekBehavior: String, CaseIterable, Codable, Sendable {
    /// Press Right/Left once -> fixed jump in 5s increments (5s, 10s, 15s, 20s...).
    case fixedStepJump
    /// Press Right/Left once -> Gear 1 (4x live visual shuttle), press again -> 8x -> 16x -> 32x -> 64x.
    case multiStageShuttle
}

/// Long-press MX Player speed curve presets.
public enum LongPressSpeedProfile: String, CaseIterable, Codable, Sendable {
    /// 精细模式：10x -> 24x -> 48x -> 96x
    case gentle
    /// MX 标准（默认，比苹果原版更快更顺手）：18x -> 45x -> 90x -> 180x
    case mxStandard
    /// 极速扫片：30x -> 75x -> 150x -> 300x
    case turbo

    public var displayName: String {
        switch self {
        case .gentle:     return "精细 (10x~96x)"
        case .mxStandard: return "MX 标准 (18x~180x)"
        case .turbo:      return "极速 (30x~300x)"
        }
    }
}

/// Preset highlight colors for the bottom translucent scrub progress bar.
public enum ScrubBarColorPreset: String, CaseIterable, Codable, Sendable {
    case skyBlue    = "#38BDF8"
    case appleBlue  = "#0A84FF"
    case emerald    = "#34D399"
    case amberGold  = "#FBBF24"
    case coralRed   = "#FB7185"
    case pureWhite  = "#FFFFFF"

    public var displayName: String {
        switch self {
        case .skyBlue:   return "极光蓝"
        case .appleBlue: return "苹果蓝"
        case .emerald:   return "翠绿"
        case .amberGold: return "琥珀金"
        case .coralRed:  return "珊瑚红"
        case .pureWhite: return "纯白"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Short-press jump step in seconds (adjustable in 5s increments: 5, 10, 15, 20 ... 120).
    public var shortSeekSeconds: Double
    public var shortPressSeekBehavior: ShortPressSeekBehavior
    public var longPressSeekMode: LongPressSeekMode
    public var longPressSpeedProfile: LongPressSpeedProfile
    public var enableTouchpadScrub: Bool

    // MX Player-style ultra-thin translucent bottom scrub bar appearance
    public var scrubBarColorHex: String
    public var scrubBarOpacity: Double
    public var scrubBarHeight: Double
    public var showScrubTimeText: Bool
    public var scrubTimeTextOpacity: Double

    // Playback resume (记忆播放 / 断点续播) & remembered LAN folders
    public var enableResumePlayback: Bool
    public var lastVisitedPaths: [String: String]

    public var readAheadCacheLimitMB: Int
    public var subtitleStyle: SubtitleStyleConfig

    public init(
        shortSeekSeconds: Double = 10,
        shortPressSeekBehavior: ShortPressSeekBehavior = .fixedStepJump,
        longPressSeekMode: LongPressSeekMode = .mxLiveKeyframeScrub,
        longPressSpeedProfile: LongPressSpeedProfile = .mxStandard,
        enableTouchpadScrub: Bool = true,
        scrubBarColorHex: String = ScrubBarColorPreset.skyBlue.rawValue,
        scrubBarOpacity: Double = 0.65,
        scrubBarHeight: Double = 5.0,
        showScrubTimeText: Bool = true,
        scrubTimeTextOpacity: Double = 0.72,
        enableResumePlayback: Bool = true,
        lastVisitedPaths: [String: String] = [:],
        readAheadCacheLimitMB: Int = 96,
        subtitleStyle: SubtitleStyleConfig = SubtitleStyleConfig()
    ) {
        self.shortSeekSeconds = shortSeekSeconds
        self.shortPressSeekBehavior = shortPressSeekBehavior
        self.longPressSeekMode = longPressSeekMode
        self.longPressSpeedProfile = longPressSpeedProfile
        self.enableTouchpadScrub = enableTouchpadScrub
        self.scrubBarColorHex = scrubBarColorHex
        self.scrubBarOpacity = scrubBarOpacity
        self.scrubBarHeight = scrubBarHeight
        self.showScrubTimeText = showScrubTimeText
        self.scrubTimeTextOpacity = scrubTimeTextOpacity
        self.enableResumePlayback = enableResumePlayback
        self.lastVisitedPaths = lastVisitedPaths
        self.readAheadCacheLimitMB = readAheadCacheLimitMB
        self.subtitleStyle = subtitleStyle
    }

    private enum CodingKeys: String, CodingKey {
        case shortSeekSeconds
        case shortPressSeekBehavior
        case longPressSeekMode
        case longPressSpeedProfile
        case enableTouchpadScrub
        case scrubBarColorHex
        case scrubBarOpacity
        case scrubBarHeight
        case showScrubTimeText
        case scrubTimeTextOpacity
        case enableResumePlayback
        case lastVisitedPaths
        case readAheadCacheLimitMB
        case subtitleStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.shortSeekSeconds = try c.decodeIfPresent(Double.self, forKey: .shortSeekSeconds) ?? 10
        self.shortPressSeekBehavior = try c.decodeIfPresent(ShortPressSeekBehavior.self, forKey: .shortPressSeekBehavior) ?? .fixedStepJump
        self.longPressSeekMode = try c.decodeIfPresent(LongPressSeekMode.self, forKey: .longPressSeekMode) ?? .mxLiveKeyframeScrub
        self.longPressSpeedProfile = try c.decodeIfPresent(LongPressSpeedProfile.self, forKey: .longPressSpeedProfile) ?? .mxStandard
        self.enableTouchpadScrub = try c.decodeIfPresent(Bool.self, forKey: .enableTouchpadScrub) ?? true
        self.scrubBarColorHex = try c.decodeIfPresent(String.self, forKey: .scrubBarColorHex) ?? ScrubBarColorPreset.skyBlue.rawValue
        self.scrubBarOpacity = try c.decodeIfPresent(Double.self, forKey: .scrubBarOpacity) ?? 0.65
        self.scrubBarHeight = try c.decodeIfPresent(Double.self, forKey: .scrubBarHeight) ?? 5.0
        self.showScrubTimeText = try c.decodeIfPresent(Bool.self, forKey: .showScrubTimeText) ?? true
        self.scrubTimeTextOpacity = try c.decodeIfPresent(Double.self, forKey: .scrubTimeTextOpacity) ?? 0.72
        self.enableResumePlayback = try c.decodeIfPresent(Bool.self, forKey: .enableResumePlayback) ?? true
        self.lastVisitedPaths = try c.decodeIfPresent([String: String].self, forKey: .lastVisitedPaths) ?? [:]
        self.readAheadCacheLimitMB = try c.decodeIfPresent(Int.self, forKey: .readAheadCacheLimitMB) ?? 96
        self.subtitleStyle = try c.decodeIfPresent(SubtitleStyleConfig.self, forKey: .subtitleStyle) ?? SubtitleStyleConfig()
    }
}
