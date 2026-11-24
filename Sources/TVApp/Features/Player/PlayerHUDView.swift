import SwiftUI
import AppPreferences

struct PlayerHUDView: View {
    @ObservedObject var engine: PlaybackCoordinator
    let title: String
    let settings: AppSettings
    let hasPrevious: Bool
    let hasNext: Bool
    let onTogglePlay: () -> Void
    let onPreviousEpisode: () -> Void
    let onNextEpisode: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onOpenSubtitles: () -> Void
    let onOpenAudioAndEngine: () -> Void
    let onToggleStats: () -> Void
    let onExit: () -> Void

    private var progress: Double {
        guard engine.duration > 0 else { return 0 }
        return min(max(engine.currentTime / engine.duration, 0), 1)
    }

    private var stepInt: Int { max(5, Int(settings.shortSeekSeconds)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Spacer()

                if abs(engine.playbackRate - 1.0) > 0.01 {
                    Text(String(format: "%.2gx", engine.playbackRate))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(TVTheme.accent, in: Capsule())
                }

                if engine.aspectMode != .fit {
                    Text(engine.aspectMode.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TVTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }

            HStack(alignment: .center, spacing: 16) {
                if hasPrevious {
                    Button(action: onPreviousEpisode) {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 22))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                }

                Button(action: onTogglePlay) {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .frame(width: 62, height: 62)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())

                if hasNext {
                    Button(action: onNextEpisode) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 22))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                }

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
                    Label("画面与音轨", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)

                Button(action: onToggleStats) {
                    Label("信息", systemImage: "info.circle")
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
                    Text("-\(stepInt)s")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(TVOptionButtonStyle())
                .disabled(engine.duration <= 0)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(Color(hex: settings.scrubBarColorHex))
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                }
                .frame(height: 8)

                Button {
                    onSeek(min(engine.duration, engine.currentTime + settings.shortSeekSeconds))
                } label: {
                    Text("+\(stepInt)s")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(TVOptionButtonStyle())
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
