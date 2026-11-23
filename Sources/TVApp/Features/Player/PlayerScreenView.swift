import SwiftUI
import AVFoundation
import NetworkVFS
import SubtitleKit
import AppPreferences

final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerRepresentable: UIViewRepresentable {
    let playerLayer: AVPlayerLayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== playerLayer.player {
            uiView.playerLayer.player = playerLayer.player
        }
        uiView.playerLayer.videoGravity = .resizeAspect
    }
}

struct PlayerScreenView: View {
    let request: PlaybackRequest

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @StateObject private var engine = AVPlayerEngineAdapter()
    @StateObject private var scrub = MXScrubController()

    @State private var provider: (any VFSProvider)?
    @State private var subtitleTrack: ParsedSubtitleTrack?
    @State private var subtitleNotice: String?
    @State private var showHUD = true
    @State private var showSubtitleDrawer = false
    @State private var showStats = false
    @State private var loadError: String?
    @State private var hudHideTask: Task<Void, Never>?
    @State private var lastReportedSecond: Int = -1

    private var style: SubtitleStyleConfig { env.settings.subtitleStyle }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerRepresentable(playerLayer: engine.playerLayer)
                .ignoresSafeArea()

            SubtitleOverlayView(
                track: subtitleTrack ?? ParsedSubtitleTrack(cues: [], format: "empty"),
                style: style,
                currentTime: engine.currentTime
            )
            .ignoresSafeArea()

            RemoteKeyCaptureView(
                isCaptureEnabled: !showSubtitleDrawer,
                onShortPress: { dir in
                    Task { await shortSeek(dir) }
                },
                onLongPressBegan: { dir in
                    beginLongHold(dir)
                },
                onLongPressEnded: {
                    endLongHold()
                },
                onPlayPause: {
                    togglePlayback()
                },
                onMenu: {
                    if showSubtitleDrawer {
                        showSubtitleDrawer = false
                    } else {
                        shutdown()
                    }
                }
            )
            .allowsHitTesting(false)

            VStack {
                if showStats {
                    statsBar
                }
                Spacer()
                if scrub.isScrubbing {
                    scrubPill
                }
                if showHUD {
                    PlayerHUDView(
                        engine: engine,
                        settings: env.settings,
                        onTogglePlay: { togglePlayback() },
                        onSeek: { seconds in
                            Task { await engine.seek(to: seconds, precise: true) }
                        },
                        onOpenSubtitles: {
                            showSubtitleDrawer = true
                            showHUD = false
                        },
                        onToggleStats: { showStats.toggle() },
                        onExit: { shutdown() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 44)

            if showSubtitleDrawer {
                HStack {
                    Spacer()
                    SubtitleSettingsDrawer(
                        style: style,
                        subtitleName: subtitleTrack.map { "\($0.format.uppercased()) · \($0.cues.count) 条" },
                        hasSubtitle: subtitleTrack != nil,
                        onStyleChange: { mutate in
                            env.updateSubtitleStyle(mutate)
                        },
                        onClose: {
                            showSubtitleDrawer = false
                            showHUD = true
                        }
                    )
                    .frame(width: 640)
                }
                .transition(.move(edge: .trailing))
            }

            if let subtitleNotice {
                VStack {
                    HStack {
                        Text(subtitleNotice)
                            .font(.system(size: 20, weight: .medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .tvGlassSurface(cornerRadius: 14)
                        Spacer()
                    }
                    .padding(50)
                    Spacer()
                }
            }

            if let loadError {
                VStack(spacing: 16) {
                    Text("播放失败")
                        .font(.system(size: 32, weight: .bold))
                    Text(loadError)
                        .font(.system(size: 20))
                        .foregroundStyle(TVTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("返回") { shutdown() }
                }
                .padding(40)
                .tvGlassSurface(cornerRadius: 24)
            }
        }
        .task { await boot() }
        .onDisappear { shutdown() }
        .onChange(of: engine.currentTime) { _, newValue in
            persistProgress(newValue)
        }
    }

    private var statsBar: some View {
        let stats = engine.currentStats()
        return HStack(spacing: 26) {
            Text(stats.videoCodec.uppercased())
            Text(stats.resolution)
            Text(stats.dynamicRange)
            Text(String(format: "%.2f fps", stats.frameRate))
            Text("丢帧 \(stats.droppedFrames)")
            Text(String(format: "读取 %.1f Mbps", stats.readMbps))
            Text(String(format: "内存 %.0f MB", stats.memoryMB))
            Spacer()
        }
        .font(.system(size: 18, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .tvGlassSurface(cornerRadius: 12)
        .padding(.top, 30)
    }

    private var scrubPill: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Text(scrub.deltaSeconds >= 0 ? ">>>" : "<<<")
                    .font(.system(size: 26, weight: .heavy, design: .monospaced))
                Text(formatted(scrub.targetTime))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                Text("/ \(formatted(engine.duration))")
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(TVTheme.secondaryText)
            }
            ProgressView(value: engine.duration > 0 ? min(max(scrub.targetTime / engine.duration, 0), 1) : 0)
                .tint(TVTheme.accent)
                .frame(width: 520)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        .tvGlassSurface(cornerRadius: 22)
        .padding(.bottom, 40)
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func boot() async {
        do {
            let newProvider = env.makeProvider(for: request.source)
            guard let newProvider else {
                loadError = "无法为该网络源创建连接器"
                return
            }
            provider = newProvider
            try await newProvider.connect()

            let stream = try await newProvider.openStream(at: request.item.path)
            let cacheConfig = StreamCacheConfiguration(
                maxCacheBytes: env.settings.readAheadCacheLimitMB * 1024 * 1024
            )
            let registered = try env.proxy.register(
                stream: stream,
                fileName: request.item.name,
                wrapWithReadAheadCache: true,
                cacheConfig: cacheConfig
            )
            try await engine.load(url: registered.url, startAt: request.resumeAt)
            DisplayModeCoordinator.shared.apply(
                info: MediaTechnicalInfo(
                    frameRate: engine.currentStats().frameRate,
                    dynamicRange: engine.currentStats().dynamicRange,
                    width: 0,
                    height: 0
                )
            )
            scheduleHUDHide()
            await loadSubtitles(provider: newProvider)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadSubtitles(provider: any VFSProvider) async {
        let directory = (request.item.path as NSString).deletingLastPathComponent
        let base = directory.isEmpty ? "/" : directory
        do {
            let entries = try await provider.listDirectory(at: base)
            let sameDir = entries
                .filter { $0.isSubtitle }
                .map { SubtitleSourceFile(name: $0.name, path: $0.path, isInSubfolder: false) }

            var folderFiles: [SubtitleSourceFile] = []
            for folderName in ["Subs", "Subtitles", "Subtitle", "字幕"] {
                let folderPath = base == "/" ? "/\(folderName)" : "\(base)/\(folderName)"
                if let children = try? await provider.listDirectory(at: folderPath) {
                    folderFiles.append(
                        contentsOf: children
                            .filter { $0.isSubtitle }
                            .map { SubtitleSourceFile(name: $0.name, path: $0.path, isInSubfolder: true) }
                    )
                }
            }

            let candidates = SubtitleMatcher.match(
                videoFileName: request.item.name,
                sameDirectoryFiles: sameDir,
                subfolderFiles: folderFiles
            )
            guard let best = candidates.first else { return }
            let data = try await provider.readFileData(at: best.path, maxBytes: 8 * 1024 * 1024)
            let parsed = SubtitleParser.parse(data: data, fileExtension: best.formatExtension)
            subtitleTrack = parsed.track
            subtitleNotice = "已自动加载外挂字幕：\(best.name)"
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                subtitleNotice = nil
            }
        } catch {
            // Subtitles are optional; playback must never fail because of them.
        }
    }

    private func togglePlayback() {
        if engine.isPlaying {
            engine.pause()
        } else {
            engine.play()
        }
        showHUD = true
        scheduleHUDHide()
    }

    private func shortSeek(_ direction: ScrubDirection) async {
        let step = env.settings.shortSeekSeconds * Double(direction.rawValue)
        let target = min(max(0, engine.currentTime + step), max(0, engine.duration))
        await engine.seek(to: target, precise: true)
        showHUD = true
        scheduleHUDHide()
    }

    private func beginLongHold(_ direction: ScrubDirection) {
        engine.pause()
        engine.setMuted(true)
        hudHideTask?.cancel()
        showHUD = false
        scrub.beginHold(
            direction: direction,
            currentPlaybackTime: engine.currentTime,
            duration: engine.duration
        ) { target in
            await engine.seekToKeyframePreview(at: target)
        }
    }

    private func endLongHold() {
        scrub.endHold { target in
            await engine.seek(to: target, precise: true)
            engine.setMuted(false)
            engine.play()
        }
    }

    private func scheduleHUDHide() {
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled, scrub.isScrubbing == false, !showSubtitleDrawer else { return }
            showHUD = false
        }
    }

    private func persistProgress(_ time: TimeInterval) {
        let second = Int(time)
        guard second != lastReportedSecond else { return }
        lastReportedSecond = second
        guard engine.duration > 0 else { return }
        let record = PlaybackHistoryRecord(
            sourceID: request.source.id,
            filePath: request.item.path,
            fileName: request.item.name,
            lastPositionSeconds: time,
            durationSeconds: engine.duration,
            lastPlayedAt: Date(),
            selectedSubtitlePath: nil,
            selectedAudioTrackID: nil
        )
        env.recordProgress(record)
    }

    private func shutdown() {
        hudHideTask?.cancel()
        engine.pause()
        DisplayModeCoordinator.shared.reset()
        if let provider {
            Task { await provider.disconnect() }
        }
        dismiss()
    }
}
