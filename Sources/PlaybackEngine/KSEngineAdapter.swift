import Foundation
import CoreMedia
import UIKit
import SwiftUI
import Combine
import os

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

/// Thread-safe one-shot continuation wrapper so superseded or timed-out KSPlayer seeks NEVER leak or hang.
private final class OneShotSeekContinuation: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    func store(_ continuation: CheckedContinuation<Void, Never>) {
        lock.withLock { $0 = continuation }
    }

    func resumeOnce() {
        let cont = lock.withLock { current -> CheckedContinuation<Void, Never>? in
            let saved = current
            current = nil
            return saved
        }
        cont?.resume()
    }
}

/// KSPlayer 5.6.2 (FFmpeg + VideoToolbox + Metal) adapter.
@MainActor
public final class KSEngineAdapter: NSObject, ObservableObject, PlayerEngineProtocol, KSPlayerLayerDelegate {
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var audioTracks: [EngineTrackInfo] = []
    @Published public private(set) var embeddedSubtitleTracks: [EngineTrackInfo] = []
    @Published public private(set) var lastError: String?
    /// Incremented whenever a new KSPlayerLayer is created so KSLayerRepresentable mounts the video view.
    @Published public private(set) var layerRevision: Int = 0

    public private(set) var playbackRate: Float = 1.0
    @Published public private(set) var aspectMode: VideoAspectMode = .fit
    public var onPlaybackEnded: (@MainActor () -> Void)?
    public private(set) var videoFormatDescription: CMFormatDescription?

    private var playerLayer: KSPlayerLayer?
    private var activeOptions: AuraKSOptions?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?
    private var stats = PlaybackStats(engineName: "KSPlayer")

    public override init() {
        super.init()
    }

    private func makeFreshOptions() -> AuraKSOptions {
        let opts = AuraKSOptions()
        opts.playerTypes = [KSMEPlayer.self, KSAVPlayer.self]
        opts.videoDecodeType = .asynchronousHardware
        opts.isAutoPlay = true
        // Always open cleanly from t=0 on a fresh layer; seek after readyToPlay for resume reliability.
        opts.isSecondOpen = false
        opts.startPlayTime = 0
        opts.isAccurateSeek = false
        opts.isSeekedAutoPlay = true
        opts.seekUsePacketCache = true
        opts.seekInterruptIO = true
        opts.seekFlags = 1
        opts.changeDV7ToDV81 = true
        opts.autoSelectEmbedSubtitle = false
        opts.videoSoftDecodeThreadCount = 4
        opts.preferredForwardBufferDuration = 1.5
        opts.maxBufferDuration = 16
        opts.formatContextOptions["probesize"] = 2 * 1024 * 1024
        opts.formatContextOptions["analyzeduration"] = 2_000_000
        opts.onVideoMetadata = { [weak self] refreshRate, formatDesc in
            guard let self else { return }
            self.videoFormatDescription = formatDesc
            DisplayModeCoordinator.shared.apply(refreshRate: refreshRate, formatDescription: formatDesc)
        }
        return opts
    }

    private func finishLoadContinuation(with result: Result<Void, Error>) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        guard let cont = loadContinuation else { return }
        loadContinuation = nil
        cont.resume(with: result)
    }

    public func makeLayerView() -> UIView? {
        playerLayer?.makeUIView()
    }

    public func updateLayerView(_ view: UIView) {
        playerLayer?.updateUIView(view)
    }

    public func load(url: URL, startAt time: TimeInterval) async throws {
        lastError = nil
        finishLoadContinuation(with: .failure(CancellationError()))

        if let existing = playerLayer {
            existing.delegate = nil
            existing.stop()
            existing.reset()
            playerLayer = nil
        }

        let opts = makeFreshOptions()
        self.activeOptions = opts

        let layer = KSPlayerLayer(url: url, options: opts, delegate: self)
        self.playerLayer = layer
        // Notify KSLayerRepresentable immediately so the Metal/VideoToolbox surface is mounted into the window!
        self.layerRevision += 1

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
            self.loadTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let timeoutErr = NSError(
                    domain: "AuraTV.KSEngine",
                    code: -1001,
                    userInfo: [NSLocalizedDescriptionKey: "播放器初始化超时，请重试"]
                )
                self.finishLoadContinuation(with: .failure(timeoutErr))
            }
            layer.prepareToPlay()
        }

        guard self.playerLayer === layer else { throw CancellationError() }
        if time > 0.5 {
            opts.isAccurateSeek = false
            opts.isSeekedAutoPlay = true
            await performGuardedSeek(layer: layer, time: time, autoPlay: true, timeoutNs: 2_500_000_000)
            layer.play()
            isPlaying = true
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
        activeOptions?.isAccurateSeek = precise
        activeOptions?.isSeekedAutoPlay = isPlaying
        await performGuardedSeek(layer: playerLayer, time: max(0, time), autoPlay: isPlaying, timeoutNs: 2_000_000_000)
    }

    public func seekToKeyframePreview(at time: TimeInterval) async {
        guard let playerLayer else { return }
        activeOptions?.isAccurateSeek = false
        activeOptions?.isSeekedAutoPlay = false
        // 500ms timeout guarantees single-flight scrubbing NEVER hangs if KSPlayer drops an older seek callback.
        await performGuardedSeek(layer: playerLayer, time: max(0, time), autoPlay: false, timeoutNs: 500_000_000)
    }

    private func performGuardedSeek(
        layer: KSPlayerLayer,
        time: TimeInterval,
        autoPlay: Bool,
        timeoutNs: UInt64
    ) async {
        let guardBox = OneShotSeekContinuation()
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNs)
            guardBox.resumeOnce()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guardBox.store(continuation)
            layer.seek(time: time, autoPlay: autoPlay) { _ in
                guardBox.resumeOnce()
            }
        }
        timeoutTask.cancel()
    }

    public func setMuted(_ muted: Bool) {
        playerLayer?.player.isMuted = muted
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        playerLayer?.player.playbackRate = rate
    }

    public func setAspectMode(_ mode: VideoAspectMode) {
        aspectMode = mode
        applyAspectModeToLayer()
    }

    private func applyAspectModeToLayer() {
        guard let player = playerLayer?.player else { return }
        switch aspectMode {
        case .fit:     player.contentMode = .scaleAspectFit
        case .fill:    player.contentMode = .scaleAspectFill
        case .stretch: player.contentMode = .scaleToFill
        }
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
                isHardwareDecoding: (activeOptions?.videoDecodeType ?? .asynchronousHardware) != .software
            )
        }
        return stats
    }

    public func shutdown() {
        isPlaying = false
        playerLayer?.delegate = nil
        playerLayer?.stop()
        playerLayer?.reset()
        playerLayer = nil
        activeOptions = nil
        layerRevision += 1
        finishLoadContinuation(with: .failure(CancellationError()))
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
        guard layer === self.playerLayer else { return }
        isPlaying = state.isPlaying
        if state == .readyToPlay {
            duration = layer.player.duration
            applyAspectModeToLayer()
            layer.player.playbackRate = playbackRate
            refreshTracks()
            if let videoTrack = layer.player.tracks(mediaType: .video).first,
               let desc = videoTrack.formatDescription {
                videoFormatDescription = desc
                DisplayModeCoordinator.shared.apply(
                    refreshRate: videoTrack.nominalFrameRate,
                    formatDescription: desc
                )
            }
            finishLoadContinuation(with: .success(()))
        }
    }

    public func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard layer === self.playerLayer else { return }
        self.currentTime = currentTime
        if totalTime > 0 {
            self.duration = totalTime
        }
    }

    public func player(layer: KSPlayerLayer, finish error: (any Error)?) {
        guard layer === self.playerLayer else { return }
        isPlaying = false
        if let error {
            lastError = error.localizedDescription
            if loadContinuation != nil {
                finishLoadContinuation(with: .failure(error))
            }
        } else if loadContinuation != nil {
            finishLoadContinuation(with: .success(()))
        } else {
            onPlaybackEnded?()
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

public final class KSContainerView: UIView {
    var mountedRevision: Int = -1
    weak var mountedLayerView: UIView?
}

/// Mounts KSPlayerLayer's Metal/VideoToolbox view reliably as soon as `layerRevision` updates.
public struct KSLayerRepresentable: UIViewRepresentable {
    @ObservedObject var adapter: KSEngineAdapter

    public init(adapter: KSEngineAdapter) {
        self.adapter = adapter
    }

    public func makeUIView(context: Context) -> KSContainerView {
        let container = KSContainerView()
        container.backgroundColor = .black
        mountIfNeeded(container)
        return container
    }

    public func updateUIView(_ uiView: KSContainerView, context: Context) {
        mountIfNeeded(uiView)
        if let mounted = uiView.mountedLayerView {
            adapter.updateLayerView(mounted)
        }
    }

    private func mountIfNeeded(_ container: KSContainerView) {
        guard container.mountedRevision != adapter.layerRevision else { return }
        container.mountedRevision = adapter.layerRevision
        container.subviews.forEach { $0.removeFromSuperview() }
        container.mountedLayerView = nil

        guard let layerView = adapter.makeLayerView() else { return }
        layerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(layerView)
        NSLayoutConstraint.activate([
            layerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            layerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            layerView.topAnchor.constraint(equalTo: container.topAnchor),
            layerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.mountedLayerView = layerView
    }
}
#endif
