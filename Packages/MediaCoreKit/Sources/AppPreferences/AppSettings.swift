import Foundation
import SubtitleKit

public enum LongPressSeekMode: String, CaseIterable, Codable, Sendable {
    case mxLiveKeyframeScrub
    case continuousFastPlay
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var shortSeekSeconds: Double
    public var longPressSeekMode: LongPressSeekMode
    public var readAheadCacheLimitMB: Int
    public var subtitleStyle: SubtitleStyleConfig

    public init(
        shortSeekSeconds: Double = 10,
        longPressSeekMode: LongPressSeekMode = .mxLiveKeyframeScrub,
        readAheadCacheLimitMB: Int = 96,
        subtitleStyle: SubtitleStyleConfig = SubtitleStyleConfig()
    ) {
        self.shortSeekSeconds = shortSeekSeconds
        self.longPressSeekMode = longPressSeekMode
        self.readAheadCacheLimitMB = readAheadCacheLimitMB
        self.subtitleStyle = subtitleStyle
    }
}
