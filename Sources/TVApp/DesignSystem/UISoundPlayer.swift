import Foundation
import AVFoundation
import QuartzCore

/// Low-latency preloaded UI sound effect player for tvOS navigation.
/// Carefully respects active `.playback` sessions (Dolby Atmos / surround HDMI output)
/// and only sets `.ambient` + `.mixWithOthers` when no video playback session is active.
@MainActor
public final class UISoundPlayer {
    public static let shared = UISoundPlayer()

    private enum SoundKind: String, CaseIterable {
        case focus = "focus_tick"
        case select = "select_click"
        case back = "back_whoosh"
    }

    private var pools: [SoundKind: [AVAudioPlayer]] = [:]
    private var poolIndex: [SoundKind: Int] = [:]
    private var lastFocusPlayTimestamp: CFTimeInterval = 0

    public var isEnabled: Bool = true

    private init() {
        preloadAll()
    }

    private func ensureSafeAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // CRITICAL: Never override `.playback` (used by KSPlayer / AVPlayer for surround & Atmos)!
        if session.category != .playback && session.category != .ambient {
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }
    }

    private func preloadAll() {
        for kind in SoundKind.allCases {
            guard let url = Bundle.main.url(forResource: kind.rawValue, withExtension: "wav", subdirectory: "Sounds")
                ?? Bundle.main.url(forResource: kind.rawValue, withExtension: "wav") else {
                continue
            }
            var players: [AVAudioPlayer] = []
            for _ in 0..<3 {
                if let player = try? AVAudioPlayer(contentsOf: url) {
                    player.volume = kind == .focus ? 0.42 : 0.55
                    player.prepareToPlay()
                    players.append(player)
                }
            }
            if !players.isEmpty {
                pools[kind] = players
                poolIndex[kind] = 0
            }
        }
    }

    public func playFocus() {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastFocusPlayTimestamp >= 0.045 else { return }
        lastFocusPlayTimestamp = now
        play(.focus)
    }

    public func playSelect() {
        guard isEnabled else { return }
        play(.select)
    }

    public func playBack() {
        guard isEnabled else { return }
        play(.back)
    }

    private func play(_ kind: SoundKind) {
        ensureSafeAudioSession()
        guard let list = pools[kind], !list.isEmpty else { return }
        let idx = (poolIndex[kind] ?? 0) % list.count
        poolIndex[kind] = (idx + 1) % list.count
        let player = list[idx]
        player.currentTime = 0
        player.play()
    }
}
