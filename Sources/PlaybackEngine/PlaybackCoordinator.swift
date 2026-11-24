import Foundation
import AVFoundation
import SwiftUI
import Combine

public enum PreferredEngineChoice: String, CaseIterable, Codable, Sendable {
    case auto = "自动路由 (推荐)"
    case ksPlayer = "KSPlayer (FFmpeg + 硬解)"
    case avPlayer = "AVPlayer (系统原生)"
}

/// Coordinates active playback engine (KSPlayer for MKV/TS/AV1/DTS/TrueHD,
/// AVPlayer optional for native MP4/MOV/Dolby Vision) and exposes unified @Published state to UI.
@MainActor
public final class PlaybackCoordinator: ObservableObject {
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var audioTracks: [EngineTrackInfo] = []
    @Published public private(set) var embeddedSubtitleTracks: [EngineTrackInfo] = []
    @Published public private(set) var activeEngineKind: PreferredEngineChoice = .ksPlayer

    public let avAdapter = AVPlayerEngineAdapter()
    #if canImport(KSPlayer) && !targetEnvironment(simulator)
    public let ksAdapter = KSEngineAdapter()
    #endif

    private var cancellables: Set<AnyCancellable> = []

    public init() {
        bindAdapters()
    }

    private func bindAdapters() {
        avAdapter.$currentTime.sink { [weak self] val in
            guard let self, self.activeEngineKind == .avPlayer else { return }
            self.currentTime = val
        }.store(in: &cancellables)
        avAdapter.$duration.sink { [weak self] val in
            guard let self, self.activeEngineKind == .avPlayer else { return }
            self.duration = val
        }.store(in: &cancellables)
        avAdapter.$isPlaying.sink { [weak self] val in
            guard let self, self.activeEngineKind == .avPlayer else { return }
            self.isPlaying = val
        }.store(in: &cancellables)
        avAdapter.$audioTracks.sink { [weak self] val in
            guard let self, self.activeEngineKind == .avPlayer else { return }
            self.audioTracks = val
        }.store(in: &cancellables)
        avAdapter.$embeddedSubtitleTracks.sink { [weak self] val in
            guard let self, self.activeEngineKind == .avPlayer else { return }
            self.embeddedSubtitleTracks = val
        }.store(in: &cancellables)

        #if canImport(KSPlayer) && !targetEnvironment(simulator)
        ksAdapter.$currentTime.sink { [weak self] val in
            guard let self, self.activeEngineKind == .ksPlayer else { return }
            self.currentTime = val
        }.store(in: &cancellables)
        ksAdapter.$duration.sink { [weak self] val in
            guard let self, self.activeEngineKind == .ksPlayer else { return }
            self.duration = val
        }.store(in: &cancellables)
        ksAdapter.$isPlaying.sink { [weak self] val in
            guard let self, self.activeEngineKind == .ksPlayer else { return }
            self.isPlaying = val
        }.store(in: &cancellables)
        ksAdapter.$audioTracks.sink { [weak self] val in
            guard let self, self.activeEngineKind == .ksPlayer else { return }
            self.audioTracks = val
        }.store(in: &cancellables)
        ksAdapter.$embeddedSubtitleTracks.sink { [weak self] val in
            guard let self, self.activeEngineKind == .ksPlayer else { return }
            self.embeddedSubtitleTracks = val
        }.store(in: &cancellables)
        #endif
    }

    public static func recommendedEngine(for fileName: String, preference: PreferredEngineChoice = .auto) -> PreferredEngineChoice {
        #if canImport(KSPlayer) && !targetEnvironment(simulator)
        switch preference {
        case .ksPlayer:
            return .ksPlayer
        case .avPlayer:
            return .avPlayer
        case .auto:
            let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
            if ["mp4", "m4v", "mov"].contains(ext) {
                return .avPlayer
            }
            return .ksPlayer
        }
        #else
        return .avPlayer
        #endif
    }

    private var activeEngine: any PlayerEngineProtocol {
        #if canImport(KSPlayer) && !targetEnvironment(simulator)
        return activeEngineKind == .ksPlayer ? ksAdapter : avAdapter
        #else
        return avAdapter
        #endif
    }

    public func load(url: URL, fileName: String, startAt time: TimeInterval, preference: PreferredEngineChoice = .auto) async throws {
        stopCurrentEngine()
        activeEngineKind = Self.recommendedEngine(for: fileName, preference: preference)
        try await activeEngine.load(url: url, startAt: time)
    }

    public func play() {
        activeEngine.play()
    }

    public func pause() {
        activeEngine.pause()
    }

    public func seek(to time: TimeInterval, precise: Bool) async {
        await activeEngine.seek(to: time, precise: precise)
    }

    public func seekToKeyframePreview(at time: TimeInterval) async {
        await activeEngine.seekToKeyframePreview(at: time)
    }

    public func setMuted(_ muted: Bool) {
        activeEngine.setMuted(muted)
    }

    public func setPlaybackRate(_ rate: Float) {
        activeEngine.setPlaybackRate(rate)
    }

    public func selectAudioTrack(id: Int32) {
        activeEngine.selectAudioTrack(id: id)
    }

    public func selectEmbeddedSubtitleTrack(id: Int32?) {
        activeEngine.selectEmbeddedSubtitleTrack(id: id)
    }

    public func currentStats() -> PlaybackStats {
        activeEngine.currentStats()
    }

    public func shutdown() {
        avAdapter.pause()
        #if canImport(KSPlayer) && !targetEnvironment(simulator)
        ksAdapter.shutdown()
        #endif
    }

    private func stopCurrentEngine() {
        avAdapter.pause()
        #if canImport(KSPlayer) && !targetEnvironment(simulator)
        ksAdapter.shutdown()
        #endif
    }
}
