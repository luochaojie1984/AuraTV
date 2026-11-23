import Foundation
import CoreMedia

/// Uniform playback surface implemented by every engine core
/// (AVPlayer/VideoToolbox today, KSPlayer or MPVKit later).
@MainActor
public protocol PlayerEngineProtocol: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var playbackRate: Float { get }

    func load(url: URL, startAt time: TimeInterval) async throws
    func play()
    func pause()
    func seek(to time: TimeInterval, precise: Bool) async
    /// Fast approximate seek used only while the Siri Remote is held down.
    func seekToKeyframePreview(at time: TimeInterval) async
    func setMuted(_ muted: Bool)
    func setPlaybackRate(_ rate: Float)
    func currentStats() -> PlaybackStats
}

public struct PlaybackStats: Sendable, Equatable {
    public var videoCodec: String
    public var resolution: String
    public var dynamicRange: String
    public var frameRate: Double
    public var droppedFrames: Int
    public var readMbps: Double
    public var memoryMB: Double
    public var isHardwareDecoding: Bool

    public init(
        videoCodec: String = "unknown",
        resolution: String = "unknown",
        dynamicRange: String = "SDR",
        frameRate: Double = 0,
        droppedFrames: Int = 0,
        readMbps: Double = 0,
        memoryMB: Double = 0,
        isHardwareDecoding: Bool = true
    ) {
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
