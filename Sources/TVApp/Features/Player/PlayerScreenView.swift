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

    @StateObject private var engine = PlaybackCoordinator()
    @StateObject private var scrub = MXScrubController()

    @State private var provider: (any VFSProvider)?
    @State private var activeStreamURL: URL?
    @State private var enginePreference: PreferredEngineChoice = .auto
    @State private var subtitleTrack: ParsedSubtitleTrack?
    @State private var subtitleNotice: String?
    @State private var showHUD = true
    @State private var showSubtitleDrawer = false
    @State private var showAudioDrawer = false
    @State private var showStats = false
    @State private var isFastPlaying = false
    @State private var fastPlayDirection: ScrubDirection = .forward
    @State private var loadError: String?
    @State private var hudHideTask: Task<Void, Never>?
    @State private var lastReportedSecond: Int = -1

    private var style: SubtitleStyleConfig { env.settings.subtitleStyle }
    private var anyDrawerOpen: Bool { showSubtitleDrawer || showAudioDrawer }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if canImport(KSPlayer) && !targetEnvironment(simulator)
            if engine.activeEngineKind == .ksPlayer {
                KSLayerRepresentable(adapter: engine.ksAdapter)
                    .ignoresSafeArea()
            } else {
                PlayerLayerRepresentable(playerLayer: engine.avAdapter.playerLayer)
                    .ignoresSafeArea()
            }
            #else
            PlayerLayerRepresentable(playerLayer: engine.avAdapter.playerLayer)
                .ignoresSafeArea()
            #endif

            SubtitleOverlayView(
                track: subtitleTrack ?? ParsedSubtitleTrack(cues: [], format: "empty"),
                style: style,
                currentTime: engine.currentTime
            )
            .ignoresSafeArea()

            RemoteKeyCaptureView(
                isCaptureEnabled: !anyDrawerOpen,
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
                    } else if showAudioDrawer {
                        showAudioDrawer = false
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
                } else if isFastPlaying {
                    fastPlayPill
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
                            showAudioDrawer = false
                            showSubtitleDrawer = true
                            showHUD = false
                        },
                        onOpenAudioAndEngine: {
                            showSubtitleDrawer = false
                            showAudioDrawer = true
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
                            Task { await env.updateSubtitleStyle(mutate) }
                        },
                        onClearSubtitle: {
                            subtitleTrack = nil
                        },
                        onClose: {
                            showSubtitleDrawer = false
                        }
                    )
                    .padding(.vertical, 40)
                    .padding(.trailing, 50)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if showAudioDrawer {
                HStack {
                    Spacer()
                    AudioAndEngineDrawer(
                        audioTracks: engine.audioTracks,
                        embeddedSubtitleTracks: engine.embeddedSubtitleTracks,
                        activeEngineKind: engine.activeEngineKind,
                        currentPreference: enginePreference,
                        onSelectAudio: { id in
                            engine.selectAudioTrack(id: id)
                        },
                        onSelectEmbeddedSubtitle: { id in
                            if id != nil {
                                // Hide external overlay if user explicitly turns on PGS/embedded subtitle
                                subtitleTrack = nil
                            }
                            engine.selectEmbeddedSubtitleTrack(id: id)
                        },
                        onSwitchEngine: { choice in
                            Task { await switchEngine(to: choice) }
                        },
                        onClose: {
                            showAudioDrawer = false
                        }
                    )
                    .padding(.vertical, 40)
                    .padding(.trailing, 50)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if let subtitleNotice {
                VStack {
                    HStack {
                        Text(subtitleNotice)
                            .font(.system(size: 18, weight: .semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .tvGlassSurface(cornerRadius: 14)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 50)
                .padding(.leading, 70)
                .transition(.opacity)
            }

            if let loadError {
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.yellow)
                    Text("无法播放该视频")
                        .font(.system(size: 30, weight: .bold))
                    Text(loadError)
                        .font(.system(size: 18))
                        .foregroundStyle(TVTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("返回") { shutdown() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(44)
                .tvGlassSurface(cornerRadius: 24)
            }
        }
        .task { await startPlayback() }
        .onChange(of: engine.currentTime) { _, newValue in
            persistProgress(newValue)
        }
        .onDisappear {
            shutdown()
        }
    }

    private var statsBar: some View {
        let s = engine.currentStats()
        return HStack(spacing: 18) {
            Text(s.engineName)
                .foregroundStyle(TVTheme.accent)
            Text(s.videoCodec)
            Text(s.resolution)
            Text(s.dynamicRange)
            Text(String(format: "%.2f fps", s.frameRate))
            Text(s.isHardwareDecoding ? "HW" : "SW")
            Text(String(format: "%.1f Mbps", s.readMbps))
            Text("掉帧 \(s.droppedFrames)")
            Text(String(format: "%.0f MB", s.memoryMB))
        }
        .font(.system(size: 16, weight: .medium, design: .monospaced))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .tvGlassSurface(cornerRadius: 12)
        .padding(.top, 30)
    }

    private var scrubPill: some View {
        let sign = scrub.deltaSeconds >= 0 ? "+" : "-"
        let arrow = scrub.deltaSeconds >= 0 ? ">>>" : "<<<"
        return VStack(spacing: 8) {
            HStack(spacing: 14) {
                Text(arrow).foregroundStyle(TVTheme.accent)
                Text("\(sign)\(formatTime(abs(scrub.deltaSeconds)))")
                    .foregroundStyle(TVTheme.accent)
                Text("|").foregroundStyle(TVTheme.tertiaryText)
                Text("\(formatTime(scrub.targetTime)) / \(formatTime(engine.duration))")
            }
            .font(.system(size: 24, weight: .bold, design: .monospaced))

            GeometryReader { proxy in
                let ratio = engine.duration > 0 ? min(max(scrub.targetTime / engine.duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(TVTheme.accent)
                        .frame(width: max(0, proxy.size.width * ratio))
                }
            }
            .frame(width: 420, height: 6)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .tvGlassSurface(cornerRadius: 20)
        .padding(.bottom, 16)
    }

    private var fastPlayPill: some View {
        HStack(spacing: 10) {
            Text(fastPlayDirection == .forward ? ">>> 3.0x 倍速播放" : "<<< 快退")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(TVTheme.accent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .tvGlassSurface(cornerRadius: 18)
        .padding(.bottom, 16)
    }

    private func startPlayback() async {
        do {
            let newProvider = try env.makeProvider(for: request.source)
            self.provider = newProvider
            try await newProvider.connect()
            let stream = try await newProvider.openStream(at: request.item.path)
            let cacheConfig = StreamCacheConfiguration(
                maxCacheBytes: env.settings.readAheadCacheLimitMB * 1024 * 1024
            )
            let registered = try env.streamProxy.register(
                stream: stream,
                fileName: request.item.name,
                wrapWithReadAheadCache: true,
                cacheConfig: cacheConfig
            )
            self.activeStreamURL = registered.url
            try await engine.load(
                url: registered.url,
                fileName: request.item.name,
                startAt: request.resumeAt,
                preference: enginePreference
            )
            if engine.activeEngineKind == .avPlayer {
                DisplayModeCoordinator.shared.apply(
                    refreshRate: Float(engine.currentStats().frameRate),
                    formatDescription: engine.avAdapter.videoFormatDescription
                )
            }
            scheduleHUDHide()
            await loadSubtitles(provider: newProvider)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func switchEngine(to choice: PreferredEngineChoice) async {
        enginePreference = choice
        guard let url = activeStreamURL else { return }
        let currentPos = engine.currentTime
        showAudioDrawer = false
        do {
            try await engine.load(
                url: url,
                fileName: request.item.name,
                startAt: currentPos,
                preference: choice
            )
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
        hudHideTask?.cancel()
        showHUD = false
        if env.settings.longPressSeekMode == .continuousFastPlay && direction == .forward {
            isFastPlaying = true
            fastPlayDirection = direction
            engine.setPlaybackRate(3.0)
            engine.play()
            return
        }

        engine.pause()
        engine.setMuted(true)
        scrub.beginHold(
            direction: direction,
            currentPlaybackTime: engine.currentTime,
            duration: engine.duration
        ) { target in
            await engine.seekToKeyframePreview(at: target)
        }
    }

    private func endLongHold() {
        if isFastPlaying {
            isFastPlaying = false
            engine.setPlaybackRate(1.0)
            return
        }
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
            guard !Task.isCancelled, scrub.isScrubbing == false, !anyDrawerOpen else { return }
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
        Task { await env.recordProgress(record) }
    }

    private func shutdown() {
        hudHideTask?.cancel()
        engine.shutdown()
        DisplayModeCoordinator.shared.reset()
        if let provider {
            Task { await provider.disconnect() }
        }
        dismiss()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
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
