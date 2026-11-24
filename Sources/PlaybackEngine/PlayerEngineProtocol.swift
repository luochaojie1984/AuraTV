import Foundation
import CoreMedia

public struct EngineTrackInfo: Identifiable, Hashable, Sendable {
    public let id: Int32
    public let name: String
    public let languageCode: String?
    public let isEnabled: Bool
    public let isImageSubtitle: Bool

    public init(
        id: Int32,
        name: String,
        languageCode: String? = nil,
        isEnabled: Bool = false,
        isImageSubtitle: Bool = false
    ) {
        self.id = id
        self.name = name
        self.languageCode = languageCode
        self.isEnabled = isEnabled
        self.isImageSubtitle = isImageSubtitle
    }
}

/// Uniform playback surface implemented by every engine core
/// (KSPlayer/FFmpeg+VideoToolbox and AVPlayer/VideoToolbox).
@MainActor
public protocol PlayerEngineProtocol: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var playbackRate: Float { get }
    var audioTracks: [EngineTrackInfo] { get }
    var embeddedSubtitleTracks: [EngineTrackInfo] { get }

    func load(url: URL, startAt time: TimeInterval) async throws
    func play()
    func pause()
    func seek(to time: TimeInterval, precise: Bool) async
    /// Fast approximate seek used only while the Siri Remote is held down.
    func seekToKeyframePreview(at time: TimeInterval) async
    func setMuted(_ muted: Bool)
    func setPlaybackRate(_ rate: Float)
    func selectAudioTrack(id: Int32)
    func selectEmbeddedSubtitleTrack(id: Int32?)
    func currentStats() -> PlaybackStats
}

public struct PlaybackStats: Sendable, Equatable {
    public var engineName: String
    public var videoCodec: String
    public var resolution: String
    public var dynamicRange: String
    public var frameRate: Double
    public var droppedFrames: Int
    public var readMbps: Double
    public var memoryMB: Double
    public var isHardwareDecoding: Bool

    public init(
        engineName: String = "AVPlayer",
        videoCodec: String = "unknown",
        resolution: String = "unknown",
        dynamicRange: String = "SDR",
        frameRate: Double = 0,
        droppedFrames: Int = 0,
        readMbps: Double = 0,
        memoryMB: Double = 0,
        isHardwareDecoding: Bool = true
    ) {
        self.engineName = engineName
        self.videoCodec = videoCodec
        self.resolution = resolution
        self.dynamicRange = dynamicRange
        self.frameRate = frameRate
        self.droppedFrames = droppedFrames
        self.readMbps = readMbps
        self.memoryMB = memoryMB
        self.isHardwareDecoding = isHardwareDecoding
    }
}

/// Source metadata used to drive `AVDisplayManager` dynamic range / frame rate.
public struct MediaTechnicalInfo: Sendable, Equatable {
    public var frameRate: Double
    public var dynamicRange: String
    public var width: Int
    public var height: Int

    public init(frameRate: Double, dynamicRange: String, width: Int, height: Int) {
        self.frameRate = frameRate
        self.dynamicRange = dynamicRange
        self.width = width
        self.height = height
    }
}
