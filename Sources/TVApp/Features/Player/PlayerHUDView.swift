import SwiftUI
import AppPreferences

struct PlayerHUDView: View {
    @ObservedObject var engine: AVPlayerEngineAdapter
    let settings: AppSettings
    let onTogglePlay: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onOpenSubtitles: () -> Void
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

                Button(action: onToggleStats) {
                    Label("性能", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)

                Button(action: onExit) {
                    Label("退出", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(TVTheme.accent)
                        .frame(width: max(0, proxy.size.width * progress))
                }
                .frame(height: 8)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard engine.duration > 0 else { return }
                    let ratio = min(max(location.x / proxy.size.width, 0), 1)
                    onSeek(ratio * engine.duration)
                }
            }
            .frame(height: 8)
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
