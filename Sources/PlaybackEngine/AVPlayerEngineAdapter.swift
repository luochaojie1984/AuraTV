import Foundation
import AVFoundation
import CoreMedia
import UIKit
import Combine

/// AVPlayer + VideoToolbox engine core.
///
/// Scrubbing strategy: while the Siri Remote is held we pause and issue
/// **approximate** seeks (keyframe tolerance = infinite), which redecode the
/// nearest I-frame and repaint the layer in a few milliseconds — that is what
/// makes the picture visibly chase the finger at > 6 fps. Releasing the key does
/// one precise seek and resumes playback.
@MainActor
public final class AVPlayerEngineAdapter: NSObject, ObservableObject, PlayerEngineProtocol {
    private let player = AVPlayer()
    private var currentItem: AVPlayerItem?
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    private var loadedDuration: TimeInterval = 0
    private var readBytes: Int64 = 0
    private var loadStart: Date?

    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isPlaying: Bool = false
    /// Kept so `AVDisplayCriteria` can be built with the real format description.
    public private(set) var videoFormatDescription: CMFormatDescription?
    public private(set) var playbackRate: Float = 1.0
    @Published public private(set) var aspectMode: VideoAspectMode = .fit
    public var onPlaybackEnded: (@MainActor () -> Void)?
    @Published public private(set) var audioTracks: [EngineTrackInfo] = []
    @Published public private(set) var embeddedSubtitleTracks: [EngineTrackInfo] = []

    public var playerLayer: AVPlayerLayer { hostLayer }

    private let hostLayer = AVPlayerLayer()
    private var stats = PlaybackStats()

    public override init() {
        super.init()
        hostLayer.player = player
        hostLayer.videoGravity = .resizeAspect
        player.actionAtItemEnd = .pause
        installTimeObserver()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = seconds.isFinite ? seconds : 0
            }
        }
    }

    public func load(url: URL, startAt time: TimeInterval) async throws {
        loadStart = Date()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 6
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.onPlaybackEnded?()
            }
        }
        currentItem = item
        player.replaceCurrentItem(with: item)

        let loadedDuration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(loadedDuration)
        duration = seconds.isFinite ? seconds : 0
        self.loadedDuration = duration

        if time > 0 {
            await seek(to: time, precise: false)
        }
        play()

        Task { @MainActor [weak self] in
            guard let self, self.currentItem === item else { return }
            if let info = await Self.probeTechnicalInfo(asset: asset) {
                guard self.currentItem === item else { return }
                self.videoFormatDescription = info.formatDescription
                self.stats = PlaybackStats(
                    engineName: "AVPlayer",
                    videoCodec: info.codec,
                    resolution: "\(info.width)x\(info.height)",
                    dynamicRange: info.dynamicRange,
                    frameRate: info.frameRate,
                    isHardwareDecoding: true
                )
            }
            guard self.currentItem === item else { return }
            await self.refreshTracks(for: item)
        }
    }

    private func refreshTracks(for item: AVPlayerItem) async {
        if let audible = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
            let selected = item.currentMediaSelection.selectedMediaOption(in: audible)
            audioTracks = audible.options.enumerated().map { idx, opt in
                EngineTrackInfo(
                    id: Int32(idx),
                    name: opt.displayName,
                    languageCode: opt.extendedLanguageTag ?? opt.locale?.language.languageCode?.identifier,
                    isEnabled: opt == selected,
                    isImageSubtitle: false
                )
            }
        } else {
            audioTracks = []
        }

        if let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            let selected = item.currentMediaSelection.selectedMediaOption(in: legible)
            embeddedSubtitleTracks = legible.options.enumerated().map { idx, opt in
                EngineTrackInfo(
                    id: Int32(idx),
                    name: opt.displayName,
                    languageCode: opt.extendedLanguageTag ?? opt.locale?.language.languageCode?.identifier,
                    isEnabled: opt == selected,
                    isImageSubtitle: false
                )
            }
        } else {
            embeddedSubtitleTracks = []
        }
    }

    public func shutdown() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        isPlaying = false
        audioTracks = []
        embeddedSubtitleTracks = []
    }

    struct ProbeResult: Sendable {
        var codec: String
        var width: Int
        var height: Int
        var frameRate: Double
        var dynamicRange: String
        var formatDescription: CMFormatDescription?
    }

    static func probeTechnicalInfo(asset: AVURLAsset) async -> ProbeResult? {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let size = try await track.load(.naturalSize)
            let rate = try await track.load(.nominalFrameRate)
            let formats = try await track.load(.formatDescriptions)
            var codec = "unknown"
            var dynamicRange = "SDR"
            if let format = formats.first {
                let subtype = CMFormatDescriptionGetMediaSubType(format)
                codec = fourCC(subtype)
                if let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any],
                   let transfer = extensions["TransferFunction"] as? String {
                    if transfer.contains("2084") || transfer.contains("PQ") {
                        dynamicRange = "HDR10"
                    } else if transfer.contains("HLG") {
                        dynamicRange = "HLG"
                    }
                }
            }
            return ProbeResult(
                codec: codec,
                width: Int(size.width),
                height: Int(size.height),
                frameRate: Double(rate),
                dynamicRange: dynamicRange,
                formatDescription: formats.first
            )
        } catch {
            return nil
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }

    public func play() {
        player.play()
        isPlaying = true
        player.rate = playbackRate
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval, precise: Bool) async {
        let clamped = min(max(0, time), duration > 0 ? duration : time)
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        if precise {
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            await player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
        }
        currentTime = clamped
    }

    public func seekToKeyframePreview(at time: TimeInterval) async {
        let clamped = min(max(0, time), duration > 0 ? duration : time)
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
        currentTime = clamped
    }

    public func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player.rate = rate
        }
    }

    public var currentVideoGravity: AVLayerVideoGravity {
        switch aspectMode {
        case .fit:     return .resizeAspect
        case .fill:    return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    public func setAspectMode(_ mode: VideoAspectMode) {
        aspectMode = mode
        hostLayer.videoGravity = currentVideoGravity
    }

    public func selectAudioTrack(id: Int32) {
        guard let item = currentItem else { return }
        Task { @MainActor in
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
                let idx = Int(id)
                if idx >= 0 && idx < group.options.count {
                    item.select(group.options[idx], in: group)
                    await self.refreshTracks(for: item)
                }
            }
        }
    }

    public func selectEmbeddedSubtitleTrack(id: Int32?) {
        guard let item = currentItem else { return }
        Task { @MainActor in
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                if let id, Int(id) >= 0, Int(id) < group.options.count {
                    item.select(group.options[Int(id)], in: group)
                } else {
                    item.select(nil, in: group)
                }
                await self.refreshTracks(for: item)
            }
        }
    }

    public func currentStats() -> PlaybackStats {
        var snapshot = stats
        if let item = currentItem {
            let accessLog = item.accessLog()
            if let last = accessLog?.events.last {
                snapshot.droppedFrames = Int(last.numberOfDroppedVideoFrames)
                snapshot.readMbps = last.transferDuration > 0
                    ? (Double(last.numberOfBytesTransferred) * 8.0 / 1_000_000.0) / last.transferDuration
                    : 0
            }
        }
        snapshot.memoryMB = Self.residentMemoryMB()
        return snapshot
    }

    static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576.0
    }
}
