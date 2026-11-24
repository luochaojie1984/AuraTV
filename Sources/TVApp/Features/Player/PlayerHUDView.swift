import SwiftUI
import AppPreferences

struct PlayerHUDView: View {
    @ObservedObject var engine: PlaybackCoordinator
    let settings: AppSettings
    let onTogglePlay: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onOpenSubtitles: () -> Void
    let onOpenAudioAndEngine: () -> Void
    let onToggleStats: () -> Void
    let onExit: () -> Void

    private var progress: Double {
        guard engine.duration > 0 else { return 0 }
        return min(max(engine.currentTime / engine.duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                Button(action: onTogglePlay) {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .frame(width: 62, height: 62)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())

                Text(timeText(engine.currentTime))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                Text("/ \(timeText(engine.duration))")
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(TVTheme.secondaryText)

                Spacer()

                Button(action: onOpenSubtitles) {
                    Label("字幕样式", systemImage: "textformat.size")
                }
                .buttonStyle(.bordered)

                Button(action: onOpenAudioAndEngine) {
                    Label("音轨/引擎", systemImage: "hifispeaker.2")
                }
                .buttonStyle(.bordered)

                Button(action: onToggleStats) {
                    Label("性能", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)

                Button(action: onExit) {
                    Label("退出", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 14) {
                Button {
                    onSeek(max(0, engine.currentTime - settings.shortSeekSeconds))
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .buttonStyle(.plain)
                .disabled(engine.duration <= 0)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(TVTheme.accent)
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                }
                .frame(height: 8)

                Button {
                    onSeek(min(engine.duration, engine.currentTime + settings.shortSeekSeconds))
                } label: {
                    Image(systemName: "goforward.10")
                }
                .buttonStyle(.plain)
                .disabled(engine.duration <= 0)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .tvGlassSurface(cornerRadius: 22)
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
