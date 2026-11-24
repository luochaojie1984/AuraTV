import Foundation
import CoreMedia
import UIKit
import SwiftUI
import Combine

#if canImport(KSPlayer) && !targetEnvironment(simulator)
import KSPlayer

@MainActor
private final class AuraKSOptions: KSOptions {
    var onVideoMetadata: (@MainActor (Float, CMFormatDescription) -> Void)?

    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription) {
        super.updateVideo(refreshRate: refreshRate, isDovi: isDovi, formatDescription: formatDescription)
        onVideoMetadata?(refreshRate, formatDescription)
    }
}

/// KSPlayer 5.6.2 (FFmpeg + VideoToolbox + Metal) adapter.
/// Supports MKV, TS, M2TS, AVI, AV1, HEVC 10-bit, Dolby Vision (including P7->P8.1),
/// HDR10/HLG, TrueHD / DTS-HD MA multi-channel LPCM, and embedded PGS/ASS subtitles.
@MainActor
public final class KSEngineAdapter: NSObject, ObservableObject, PlayerEngineProtocol, KSPlayerLayerDelegate {
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var audioTracks: [EngineTrackInfo] = []
    @Published public private(set) var embeddedSubtitleTracks: [EngineTrackInfo] = []
    @Published public private(set) var lastError: String?

    public private(set) var playbackRate: Float = 1.0
    public private(set) var videoFormatDescription: CMFormatDescription?

    private var playerLayer: KSPlayerLayer?
    private var options: AuraKSOptions
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var stats = PlaybackStats(engineName: "KSPlayer")

    public override init() {
        let opts = AuraKSOptions()
        opts.playerTypes = [KSMEPlayer.self, KSAVPlayer.self]
        opts.videoDecodeType = .asynchronousHardware
        opts.isAutoPlay = true
        opts.isAccurateSeek = true
        opts.isSeekedAutoPlay = true
        opts.changeDV7ToDV81 = true
        opts.autoSelectEmbedSubtitle = false
        opts.preferredForwardBufferDuration = 6
        opts.maxBufferDuration = 18
        self.options = opts
        super.init()

        opts.onVideoMetadata = { [weak self] refreshRate, formatDesc in
            guard let self else { return }
            self.videoFormatDescription = formatDesc
            DisplayModeCoordinator.shared.apply(refreshRate: refreshRate, formatDescription: formatDesc)
        }
    }

    public func makeLayerView() -> UIView {
        if let playerLayer {
            return playerLayer.makeUIView()
        }
        let view = UIView()
        view.backgroundColor = .black
        return view
    }

    public func updateLayerView(_ view: UIView) {
        playerLayer?.updateUIView(view)
    }

    public func load(url: URL, startAt time: TimeInterval) async throws {
        lastError = nil
        options.startPlayTime = max(0, time)
        options.isAccurateSeek = true
        options.isSeekedAutoPlay = true

        if let existing = playerLayer {
            existing.stop()
            existing.reset()
        }

        let layer = KSPlayerLayer(url: url, options: options, delegate: self)
        self.playerLayer = layer

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
            layer.prepareToPlay()
        }
    }

    public func play() {
        playerLayer?.play()
        isPlaying = true
    }

    public func pause() {
        playerLayer?.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval, precise: Bool) async {
        guard let playerLayer else { return }
        options.isAccurateSeek = precise
        options.isSeekedAutoPlay = isPlaying
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playerLayer.seek(time: max(0, time), autoPlay: isPlaying) { _ in
                continuation.resume()
            }
        }
    }

    public func seekToKeyframePreview(at time: TimeInterval) async {
        guard let playerLayer else { return }
        options.isAccurateSeek = false
        options.isSeekedAutoPlay = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playerLayer.seek(time: max(0, time), autoPlay: false) { _ in
                continuation.resume()
            }
        }
    }

    public func setMuted(_ muted: Bool) {
        playerLayer?.player.isMuted = muted
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        playerLayer?.player.playbackRate = rate
    }

    public func selectAudioTrack(id: Int32) {
        guard let player = playerLayer?.player else { return }
        if let match = player.tracks(mediaType: .audio).first(where: { $0.trackID == id }) {
            player.select(track: match)
            refreshTracks()
        }
    }

    public func selectEmbeddedSubtitleTrack(id: Int32?) {
        guard let player = playerLayer?.player else { return }
        let subTracks = player.tracks(mediaType: .subtitle)
        if let id, let match = subTracks.first(where: { $0.trackID == id }) {
            player.select(track: match)
        } else {
            for track in subTracks {
                track.isEnabled = false
            }
        }
        refreshTracks()
    }

    public func currentStats() -> PlaybackStats {
        if let player = playerLayer?.player {
            let info = player.dynamicInfo
            info.update()
            let size = player.naturalSize
            let res = (size.width > 0 && size.height > 0) ? "\(Int(size.width))x\(Int(size.height))" : stats.resolution
            let rangeText: String
            switch player.dynamicRange {
            case .dolbyVision: rangeText = "Dolby Vision"
            case .hdr10: rangeText = "HDR10"
            case .hlg: rangeText = "HLG"
            default: rangeText = "SDR"
            }
            let fps = Double(player.nominalFrameRate)
            let codec = player.videoFormat ?? stats.videoCodec
            stats = PlaybackStats(
                engineName: "KSPlayer",
                videoCodec: codec,
                resolution: res,
                dynamicRange: rangeText,
                frameRate: fps > 0 ? fps : stats.frameRate,
                droppedFrames: Int(info.droppedVideoFrameCount),
                readMbps: Double(info.networkSpeed) * 8.0 / 1_000_000.0,
                memoryMB: Self.residentMemoryMB(),
                isHardwareDecoding: options.videoDecodeType != .software
            )
        }
        return stats
    }

    public func shutdown() {
        playerLayer?.stop()
        playerLayer?.reset()
        playerLayer = nil
        if let cont = loadContinuation {
            loadContinuation = nil
            cont.resume(throwing: CancellationError())
        }
    }

    private func refreshTracks() {
        guard let player = playerLayer?.player else { return }
        audioTracks = player.tracks(mediaType: .audio).map { track in
            EngineTrackInfo(
                id: track.trackID,
                name: track.name,
                languageCode: track.languageCode,
                isEnabled: track.isEnabled,
                isImageSubtitle: false
            )
        }
        embeddedSubtitleTracks = player.tracks(mediaType: .subtitle).map { track in
            EngineTrackInfo(
                id: track.trackID,
                name: track.name,
                languageCode: track.languageCode,
                isEnabled: track.isEnabled,
                isImageSubtitle: track.isImageSubtitle
            )
        }
    }

    // MARK: - KSPlayerLayerDelegate

    public func player(layer: KSPlayerLayer, state: KSPlayerState) {
        isPlaying = state.isPlaying
        if state == .readyToPlay {
            duration = layer.player.duration
            refreshTracks()
            if let videoTrack = layer.player.tracks(mediaType: .video).first,
               let desc = videoTrack.formatDescription {
                videoFormatDescription = desc
                DisplayModeCoordinator.shared.apply(
                    refreshRate: videoTrack.nominalFrameRate,
                    formatDescription: desc
                )
            }
            if let cont = loadContinuation {
                loadContinuation = nil
                cont.resume()
            }
        }
    }

    public func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        self.currentTime = currentTime
        if totalTime > 0 {
            self.duration = totalTime
        }
    }

    public func player(layer: KSPlayerLayer, finish error: (any Error)?) {
        isPlaying = false
        if let error {
            lastError = error.localizedDescription
            if let cont = loadContinuation {
                loadContinuation = nil
                cont.resume(throwing: error)
            }
        } else if let cont = loadContinuation {
            loadContinuation = nil
            cont.resume()
        }
    }

    public func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }
}

public struct KSLayerRepresentable: UIViewRepresentable {
    @ObservedObject var adapter: KSEngineAdapter

    public init(adapter: KSEngineAdapter) {
        self.adapter = adapter
    }

    public func makeUIView(context: Context) -> UIView {
        adapter.makeLayerView()
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        adapter.updateLayerView(uiView)
    }
}
#endif
