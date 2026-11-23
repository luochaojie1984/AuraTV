import Foundation

public enum SubtitleFontWeight: String, CaseIterable, Codable, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

public enum SubtitleColorPreset: String, CaseIterable, Codable, Sendable {
    case pureWhite = "#FFFFFF"
    case cinemaYellow = "#FFD700"
    case warmIvory = "#FFF5DC"
    case skyCyan = "#7CE8FF"
    case softGreen = "#A8FF9E"
}

public struct SubtitleStyleConfig: Codable, Equatable, Sendable {
    public var fontSize: Double
    public var bottomOffsetRatio: Double
    public var textColorHex: String
    public var textOpacity: Double
    public var fontWeight: SubtitleFontWeight
    public var outlineWidth: Double
    public var outlineColorHex: String
    public var backgroundOpacity: Double
    public var delaySeconds: Double
    public var overrideASSStyles: Bool

    public init(
        fontSize: Double = 56,
        bottomOffsetRatio: Double = 0.06,
        textColorHex: String = SubtitleColorPreset.warmIvory.rawValue,
        textOpacity: Double = 0.92,
        fontWeight: SubtitleFontWeight = .semibold,
        outlineWidth: Double = 2.5,
        outlineColorHex: String = "#000000",
        backgroundOpacity: Double = 0.0,
        delaySeconds: Double = 0.0,
        overrideASSStyles: Bool = false
    ) {
        self.fontSize = fontSize
        self.bottomOffsetRatio = bottomOffsetRatio
        self.textColorHex = textColorHex
        self.textOpacity = textOpacity
        self.fontWeight = fontWeight
        self.outlineWidth = outlineWidth
        self.outlineColorHex = outlineColorHex
        self.backgroundOpacity = backgroundOpacity
        self.delaySeconds = delaySeconds
        self.overrideASSStyles = overrideASSStyles
    }
}
