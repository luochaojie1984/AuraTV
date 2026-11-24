import Foundation
import SubtitleKit

public enum LongPressSeekMode: String, CaseIterable, Codable, Sendable {
    case mxLiveKeyframeScrub
    case continuousFastPlay
}

public enum ShortPressSeekBehavior: String, CaseIterable, Codable, Sendable {
    /// Press Right/Left once -> Gear 1 (4x live visual shuttle), press again -> 8x -> 16x -> 32x -> 64x!
    case multiStageShuttle
    /// Press Right/Left once -> fixed jump (±10s / ±15s / ±30s).
    case fixedStepJump
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var shortSeekSeconds: Double
    public var shortPressSeekBehavior: ShortPressSeekBehavior
    public var longPressSeekMode: LongPressSeekMode
    public var enableTouchpadScrub: Bool
    public var readAheadCacheLimitMB: Int
    public var subtitleStyle: SubtitleStyleConfig

    public init(
        shortSeekSeconds: Double = 10,
        shortPressSeekBehavior: ShortPressSeekBehavior = .multiStageShuttle,
        longPressSeekMode: LongPressSeekMode = .mxLiveKeyframeScrub,
        enableTouchpadScrub: Bool = true,
        readAheadCacheLimitMB: Int = 96,
        subtitleStyle: SubtitleStyleConfig = SubtitleStyleConfig()
    ) {
        self.shortSeekSeconds = shortSeekSeconds
        self.shortPressSeekBehavior = shortPressSeekBehavior
        self.longPressSeekMode = longPressSeekMode
        self.enableTouchpadScrub = enableTouchpadScrub
        self.readAheadCacheLimitMB = readAheadCacheLimitMB
        self.subtitleStyle = subtitleStyle
    }

    private enum CodingKeys: String, CodingKey {
        case shortSeekSeconds
        case shortPressSeekBehavior
        case longPressSeekMode
        case enableTouchpadScrub
        case readAheadCacheLimitMB
        case subtitleStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.shortSeekSeconds = try c.decodeIfPresent(Double.self, forKey: .shortSeekSeconds) ?? 10
        self.shortPressSeekBehavior = try c.decodeIfPresent(ShortPressSeekBehavior.self, forKey: .shortPressSeekBehavior) ?? .multiStageShuttle
        self.longPressSeekMode = try c.decodeIfPresent(LongPressSeekMode.self, forKey: .longPressSeekMode) ?? .mxLiveKeyframeScrub
        self.enableTouchpadScrub = try c.decodeIfPresent(Bool.self, forKey: .enableTouchpadScrub) ?? true
        self.readAheadCacheLimitMB = try c.decodeIfPresent(Int.self, forKey: .readAheadCacheLimitMB) ?? 96
        self.subtitleStyle = try c.decodeIfPresent(SubtitleStyleConfig.self, forKey: .subtitleStyle) ?? SubtitleStyleConfig()
    }
}
