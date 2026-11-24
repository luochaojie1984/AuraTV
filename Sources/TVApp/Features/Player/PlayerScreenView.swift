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

    @State private var scrubEngine = LiveKeyframeScrubEngine()
    @State private var scrubPrepareTask: Task<Void, Never>?
    @State private var activeStreamToken: String?
    @State private var activeStreamURL: URL?
    @State private var enginePreference: PreferredEngineChoice = .auto
    @State private var subtitleTrack: ParsedSubtitleTrack?
    @State private var topNotice: String?
    @State private var showHUD = false
    @State private var showSubtitleDrawer = false
    @State private var showAudioDrawer = false
    @State private var showStats = false
    @State private var isFastPlaying = false
    @State private var fastPlayDirection: ScrubDirection = .forward
    @State private var loadError: String?
    @State private var hudHideTask: Task<Void, Never>?
    @State private var noticeTask: Task<Void, Never>?
    @State private var lastReportedSecond: Int = -1
    @State private var didShutdown: Bool = false

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

            // Direct CoreAnimation CALayer live-frame display (<0.1ms swap, ZERO SwiftUI view-tree diffing!)
            ScrubFrameDisplayView(presenter: scrub.framePresenter)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            SubtitleOverlayView(
                track: subtitleTrack ?? ParsedSubtitleTrack(cues: [], format: "empty"),
                style: style,
                currentTime: (scrub.isScrubbing || scrub.isCommitting) ? scrub.displayedFrameTime : engine.currentTime
            )
            .ignoresSafeArea()

            RemoteKeyCaptureView(
                isCaptureEnabled: !showHUD && !anyDrawerOpen && loadError == nil,
                enableTouchpadScrub: env.settings.enableTouchpadScrub,
                onShortPress: { dir in
                    handleShortPress(dir)
                },
                onLongPressBegan: { dir in
                    beginLongHold(dir)
                },
                onLongPressEnded: {
                    endLongHold()
                },
                onTouchpadPanBegan: {
                    beginTouchpadScrub()
                },
                onTouchpadPanChanged: { dx, vel in
                    scrub.updateTouchpadPan(deltaPoints: dx, velocityPointsPerSec: vel)
                },
                onTouchpadPanEnded: {
                    endTouchpadScrub()
                },
                onSelectPress: {
                    if scrub.isScrubbing {
                        commitActiveScrub()
                    } else {
                        showHUD = true
                        scheduleHUDHide()
                    }
                },
                onShowHUD: {
                    if scrub.isScrubbing {
                        commitActiveScrub()
                    }
                    showHUD = true
                    scheduleHUDHide()
                },
                onPlayPause: {
                    if scrub.isScrubbing {
                        commitActiveScrub()
                    } else {
                        togglePlayback()
                    }
                },
                onMenu: {
                    if scrub.isScrubbing {
                        commitActiveScrub()
                    } else {
                        shutdown()
                    }
                }
            )
            .ignoresSafeArea()
            .allowsHitTesting(!showHUD && !anyDrawerOpen && loadError == nil)

            // Top stats & HUD overlay
            VStack {
                if showStats {
                    statsBar
                }
                Spacer()
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
                    .padding(.horizontal, 60)
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Ultra-thin MX Player-style translucent progress bar pinned flush to the bottom edge
            if !showHUD && (scrub.isShowingBar || isFastPlaying) {
                VStack {
                    Spacer()
                    mxBottomScrubBar
                }
                .padding(.horizontal, 44)
                .padding(.bottom, 16)
                .allowsHitTesting(false)
            }

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

            if let topNotice {
                VStack {
                    HStack {
                        Text(topNotice)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.45), in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 42)
                .padding(.leading, 56)
                .allowsHitTesting(false)
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
        .onExitCommand {
            if scrub.isScrubbing {
                commitActiveScrub()
            } else if showSubtitleDrawer {
                showSubtitleDrawer = false
            } else if showAudioDrawer {
                showAudioDrawer = false
            } else if showHUD {
                hudHideTask?.cancel()
                showHUD = false
            } else {
                shutdown()
            }
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

    /// Ultra-thin MX Player-style transparent progress bar at the very bottom edge (minimal video obstruction).
    private var mxBottomScrubBar: some View {
        let barColor = Color(hex: env.settings.scrubBarColorHex)
        let barOpacity = env.settings.scrubBarOpacity
        let barHeight = CGFloat(env.settings.scrubBarHeight)
        let timeOpacity = env.settings.scrubTimeTextOpacity
        let displayTime = isFastPlaying ? engine.currentTime : scrub.targetTime
        let ratio = engine.duration > 0 ? min(max(displayTime / engine.duration, 0), 1) : 0

        let leftLabel: String = {
            if isFastPlaying {
                return fastPlayDirection == .forward ? ">>> 3.0x" : "<<<"
            }
            let sign = scrub.deltaSeconds >= 0 ? "+" : "-"
            let delta = formatTime(abs(scrub.deltaSeconds))
            let badge = scrub.speedLabel
            return badge.isEmpty ? "\(sign)\(delta)" : "\(badge)  \(sign)\(delta)"
        }()

        return VStack(spacing: 6) {
            if env.settings.showScrubTimeText {
                HStack {
                    Text(leftLabel)
                    Spacer()
                    Text("\(formatTime(displayTime)) / \(formatTime(engine.duration))")
                }
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(timeOpacity))
                .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
                .padding(.horizontal, 4)
            }

            GeometryReader { proxy in
                let fillWidth = max(0, proxy.size.width * ratio)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22 * barOpacity))
                    Capsule()
                        .fill(barColor.opacity(barOpacity))
                        .frame(width: fillWidth)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(barColor.opacity(min(1.0, barOpacity + 0.28)))
                        .frame(width: 3, height: barHeight + 4)
                        .offset(x: max(0, min(proxy.size.width - 3, fillWidth - 1.5)))
                }
            }
            .frame(height: barHeight)
        }
    }

    private func startPlayback() async {
        do {
            let activeProvider: any VFSProvider
            let stream: any VFSRandomAccessStream
            do {
                let p = try await env.connectedProvider(for: request.source)
                stream = try await p.openStream(at: request.item.path)
                activeProvider = p
            } catch {
                // Transparently reconnect once if cached SMB/WebDAV session idled out
                let p = try await env.connectedProvider(for: request.source, forceReconnect: true)
                stream = try await p.openStream(at: request.item.path)
                activeProvider = p
            }

            let cacheConfig = StreamCacheConfiguration(
                maxCacheBytes: env.settings.readAheadCacheLimitMB * 1024 * 1024
            )
            let registered = try env.proxy.register(
                stream: stream,
                fileName: request.item.name,
                wrapWithReadAheadCache: true,
                cacheConfig: cacheConfig
            )
            self.activeStreamToken = registered.token
            self.activeStreamURL = registered.url

            let effectiveStartAt = env.settings.enableResumePlayback ? request.resumeAt : 0
            try await engine.load(
                url: registered.url,
                fileName: request.item.name,
                startAt: effectiveStartAt,
                preference: enginePreference
            )
            if engine.activeEngineKind == .avPlayer {
                DisplayModeCoordinator.shared.apply(
                    refreshRate: Float(engine.currentStats().frameRate),
                    formatDescription: engine.avAdapter.videoFormatDescription
                )
            }

            if effectiveStartAt >= 5 {
                showTopNotice("已从 \(formatTime(effectiveStartAt)) 继续播放")
            }

            // Warm up dedicated hardware keyframe scrub engine silently in background
            let localScrub = scrubEngine
            let streamURL = registered.url
            scrubPrepareTask?.cancel()
            scrubPrepareTask = Task.detached(priority: .utility) {
                await localScrub.prepare(url: streamURL)
            }
            scheduleHUDHide()
            await loadSubtitles(provider: activeProvider)
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
            showTopNotice("已自动加载外挂字幕：\(best.name)")
        } catch {
            // Subtitles are optional; playback must never fail because of them.
        }
    }

    private func showTopNotice(_ message: String) {
        noticeTask?.cancel()
        topNotice = message
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            guard !Task.isCancelled else { return }
            topNotice = nil
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

    // MARK: - MX Live Scrub Controls

    private func makePreviewFrameLoader() -> MXScrubController.PreviewFrameLoader {
        let localScrubEngine = scrubEngine
        let localEngine = engine
        return { target in
            let outcome = await localScrubEngine.decodePreviewFrame(at: target)
            switch outcome {
            case .frame, .unchanged:
                return outcome
            case .unavailable:
                await localEngine.seekToKeyframePreview(at: target)
                return .unavailable
            }
        }
    }

    private func enterScrubHardwareStateIfNeeded() {
        hudHideTask?.cancel()
        showHUD = false
        guard !scrub.isScrubbing else { return }
        scrubEngine.resetTracking()
        if let token = activeStreamToken {
            env.proxy.setScrubMode(true, for: token)
        }
        engine.pause()
        engine.setMuted(true)
    }

    private func commitActiveScrub() {
        let token = activeStreamToken
        scrub.commit { finalTarget in
            if let token {
                env.proxy.setScrubMode(false, for: token)
            }
            await engine.seek(to: finalTarget, precise: true)
            engine.setMuted(false)
            engine.play()
        }
    }

    private func handleShortPress(_ direction: ScrubDirection) {
        if env.settings.shortPressSeekBehavior == .multiStageShuttle {
            enterScrubHardwareStateIfNeeded()
            let result = scrub.stepShuttle(
                direction: direction,
                currentPlaybackTime: engine.currentTime,
                duration: engine.duration,
                onPreviewFrame: makePreviewFrameLoader()
            )
            if case .exitedToNormalPlayback = result {
                commitActiveScrub()
            }
        } else {
            // Default: fixed 5s-increment step jump with rapid multi-tap coalescing & live frame preview
            enterScrubHardwareStateIfNeeded()
            let token = activeStreamToken
            scrub.triggerShortStep(
                direction: direction,
                stepSeconds: env.settings.shortSeekSeconds,
                currentPlaybackTime: engine.currentTime,
                duration: engine.duration,
                onPreviewFrame: makePreviewFrameLoader()
            ) { finalTarget in
                if let token {
                    env.proxy.setScrubMode(false, for: token)
                }
                await engine.seek(to: finalTarget, precise: true)
                engine.setMuted(false)
                engine.play()
            }
        }
    }

    private func beginLongHold(_ direction: ScrubDirection) {
        hudHideTask?.cancel()
        showHUD = false
        if env.settings.longPressSeekMode == .continuousFastPlay && direction == .forward && !scrub.isScrubbing {
            isFastPlaying = true
            fastPlayDirection = direction
            engine.setPlaybackRate(3.0)
            engine.play()
            return
        }

        enterScrubHardwareStateIfNeeded()
        scrub.beginHold(
            direction: direction,
            speedProfile: env.settings.longPressSpeedProfile,
            currentPlaybackTime: engine.currentTime,
            duration: engine.duration,
            onPreviewFrame: makePreviewFrameLoader()
        )
    }

    private func endLongHold() {
        if isFastPlaying {
            isFastPlaying = false
            engine.setPlaybackRate(1.0)
            return
        }
        if scrub.isScrubbing {
            commitActiveScrub()
        }
    }

    private func beginTouchpadScrub() {
        enterScrubHardwareStateIfNeeded()
        scrub.beginTouchpadPan(
            currentPlaybackTime: engine.currentTime,
            duration: engine.duration,
            onPreviewFrame: makePreviewFrameLoader()
        )
    }

    private func endTouchpadScrub() {
        if scrub.isScrubbing {
            commitActiveScrub()
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
        guard env.settings.enableResumePlayback else { return }
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
        guard !didShutdown else { return }
        didShutdown = true
        hudHideTask?.cancel()
        noticeTask?.cancel()
        scrubPrepareTask?.cancel()
        scrub.cancelAll()
        if let token = activeStreamToken {
            env.proxy.setScrubMode(false, for: token)
            env.proxy.unregister(token: token)
            activeStreamToken = nil
        }
        let localScrub = scrubEngine
        Task { await localScrub.close() }
        engine.shutdown()
        DisplayModeCoordinator.shared.reset()
        // NOTE: Keep shared LAN provider warm in AppEnvironment so returning to folder & next video needs zero reconnect!
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
