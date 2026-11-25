import SwiftUI
import UIKit
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
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== playerLayer.player {
            uiView.playerLayer.player = playerLayer.player
        }
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
    }
}

struct PlayerScreenView: View {
    let request: PlaybackRequest

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @StateObject private var engine = PlaybackCoordinator()
    @StateObject private var scrub = MXScrubController()

    @State private var currentItem: VFSFileItem
    @State private var activeProvider: (any VFSProvider)?
    @State private var scrubEngine = LiveKeyframeScrubEngine()
    @State private var scrubPrepareTask: Task<Void, Never>?
    @State private var activeStreamToken: String?
    @State private var activeStreamURL: URL?
    @State private var enginePreference: PreferredEngineChoice = .auto

    @State private var availableExternalSubtitles: [MatchedSubtitleCandidate] = []
    @State private var selectedExternalSubtitlePath: String?
    @State private var subtitleTrack: ParsedSubtitleTrack?
    @State private var suppressExternalSubtitle: Bool = false

    @State private var isLoadingMedia = true
    @State private var nextEpisodeCountdown: Int?
    @State private var nextEpisodeTask: Task<Void, Never>?
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

    init(request: PlaybackRequest) {
        self.request = request
        self._currentItem = State(initialValue: request.item)
    }

    private var style: SubtitleStyleConfig { env.settings.subtitleStyle }
    private var anyDrawerOpen: Bool { showSubtitleDrawer || showAudioDrawer }

    private var currentPlaylistIndex: Int? {
        request.playlist.firstIndex(where: { $0.path == currentItem.path })
    }

    private var previousEpisode: VFSFileItem? {
        guard let idx = currentPlaylistIndex, idx > 0 else { return nil }
        return request.playlist[idx - 1]
    }

    private var nextEpisode: VFSFileItem? {
        guard let idx = currentPlaylistIndex, idx + 1 < request.playlist.count else { return nil }
        return request.playlist[idx + 1]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if canImport(KSPlayer) && !targetEnvironment(simulator)
            if engine.activeEngineKind == .ksPlayer {
                KSLayerRepresentable(adapter: engine.ksAdapter)
                    .ignoresSafeArea()
            } else {
                PlayerLayerRepresentable(
                    playerLayer: engine.avAdapter.playerLayer,
                    videoGravity: engine.avAdapter.currentVideoGravity
                )
                .ignoresSafeArea()
            }
            #else
            PlayerLayerRepresentable(
                playerLayer: engine.avAdapter.playerLayer,
                videoGravity: engine.avAdapter.currentVideoGravity
            )
            .ignoresSafeArea()
            #endif

            ScrubFrameDisplayView(presenter: scrub.framePresenter)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            SubtitleOverlayView(
                track: (suppressExternalSubtitle ? nil : subtitleTrack) ?? ParsedSubtitleTrack(cues: [], format: "empty"),
                style: style,
                currentTime: (scrub.isScrubbing || scrub.isCommitting) ? scrub.displayedFrameTime : engine.currentTime
            )
            .ignoresSafeArea()

            RemoteKeyCaptureView(
                isCaptureEnabled: !showHUD && !anyDrawerOpen && loadError == nil && nextEpisodeCountdown == nil,
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
                        UISoundPlayer.shared.playBack()
                        shutdown()
                    }
                }
            )
            .ignoresSafeArea()
            .allowsHitTesting(!showHUD && !anyDrawerOpen && loadError == nil && nextEpisodeCountdown == nil)

            VStack {
                if showStats {
                    statsBar
                }
                Spacer()
                if showHUD {
                    PlayerHUDView(
                        engine: engine,
                        title: currentItem.name,
                        settings: env.settings,
                        hasPrevious: previousEpisode != nil,
                        hasNext: nextEpisode != nil,
                        onTogglePlay: { togglePlayback() },
                        onPreviousEpisode: {
                            if let prev = previousEpisode {
                                Task { await switchToEpisode(prev) }
                            }
                        },
                        onNextEpisode: {
                            if let next = nextEpisode {
                                Task { await switchToEpisode(next) }
                            }
                        },
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

            if !showHUD && (scrub.isShowingBar || isFastPlaying) {
                VStack {
                    Spacer()
                    mxBottomScrubBar
                }
                .padding(.horizontal, 44)
                .padding(.bottom, 16)
                .allowsHitTesting(false)
            }

            if isLoadingMedia && loadError == nil {
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text(currentItem.name)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .frame(maxWidth: 680)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 24)
                .tvGlassSurface(cornerRadius: 22)
                .transition(.opacity)
            }

            if let countdown = nextEpisodeCountdown, let nextEp = nextEpisode {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("即将播放下一集（\(countdown)s）")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(TVTheme.accent)
                            Text(nextEp.name)
                                .font(.system(size: 20, weight: .semibold))
                                .lineLimit(2)
                            HStack(spacing: 12) {
                                Button("立即播放") {
                                    cancelNextEpisodeCountdown()
                                    Task { await switchToEpisode(nextEp) }
                                }
                                .buttonStyle(TVOptionButtonStyle())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(TVTheme.accent.opacity(0.45), in: Capsule())

                                Button("取消") {
                                    cancelNextEpisodeCountdown()
                                }
                                .buttonStyle(TVOptionButtonStyle())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(24)
                        .frame(width: 460, alignment: .leading)
                        .tvGlassSurface(cornerRadius: 22)
                    }
                    .padding(.trailing, 54)
                    .padding(.bottom, 46)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if showSubtitleDrawer {
                HStack {
                    Spacer()
                    SubtitleSettingsDrawer(
                        style: style,
                        externalSubtitles: availableExternalSubtitles,
                        selectedExternalPath: selectedExternalSubtitlePath,
                        onSelectExternalSubtitle: { candidate in
                            Task { await selectExternalSubtitle(candidate) }
                        },
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
                        playbackRate: engine.playbackRate,
                        aspectMode: engine.aspectMode,
                        onSelectRate: { rate in
                            engine.setPlaybackRate(rate)
                        },
                        onSelectAspectMode: { mode in
                            engine.setAspectMode(mode)
                        },
                        onSelectAudio: { id in
                            engine.selectAudioTrack(id: id)
                        },
                        onSelectEmbeddedSubtitle: { id in
                            suppressExternalSubtitle = (id != nil)
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
        .task {
            engine.onPlaybackEnded = {
                handlePlaybackEnded()
            }
            await startPlayback(item: currentItem, startAt: request.resumeAt)
        }
        .onChange(of: engine.currentTime) { _, newValue in
            persistProgress(newValue)
        }
        .onChange(of: engine.isPlaying) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: scrub.isScrubbing) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: isLoadingMedia) { _, _ in
            updateIdleTimer()
        }
        .onExitCommand {
            if scrub.isScrubbing {
                commitActiveScrub()
            } else if nextEpisodeCountdown != nil {
                UISoundPlayer.shared.playBack()
                cancelNextEpisodeCountdown()
            } else if showSubtitleDrawer {
                UISoundPlayer.shared.playBack()
                showSubtitleDrawer = false
            } else if showAudioDrawer {
                UISoundPlayer.shared.playBack()
                showAudioDrawer = false
            } else if showHUD {
                UISoundPlayer.shared.playBack()
                hudHideTask?.cancel()
                showHUD = false
            } else {
                UISoundPlayer.shared.playBack()
                shutdown()
            }
        }
        .onDisappear {
            shutdown()
        }
    }

    private func updateIdleTimer() {
        let keepAwake = !didShutdown && (engine.isPlaying || scrub.isScrubbing || isLoadingMedia)
        UIApplication.shared.isIdleTimerDisabled = keepAwake
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

    private func startPlayback(item: VFSFileItem, startAt: TimeInterval) async {
        isLoadingMedia = true
        loadError = nil
        updateIdleTimer()

        do {
            let provider: any VFSProvider
            let stream: any VFSRandomAccessStream
            do {
                let p = try await env.connectedProvider(for: request.source)
                stream = try await p.openStream(at: item.path)
                provider = p
            } catch {
                let p = try await env.connectedProvider(for: request.source, forceReconnect: true)
                stream = try await p.openStream(at: item.path)
                provider = p
            }
            self.activeProvider = provider

            let maxCacheBytes = env.settings.readAheadCacheLimitMB * 1024 * 1024
            let edgeBytes = min(16 * 1024 * 1024, max(4 * 1024 * 1024, maxCacheBytes / 4))
            let cacheConfig = StreamCacheConfiguration(
                maxCacheBytes: maxCacheBytes,
                protectedEdgeBytes: edgeBytes
            )
            let registered = try env.proxy.register(
                stream: stream,
                fileName: item.name,
                wrapWithReadAheadCache: true,
                cacheConfig: cacheConfig
            )
            self.activeStreamToken = registered.token
            self.activeStreamURL = registered.url

            let localScrub = scrubEngine
            let streamURL = registered.url
            let smbProvider = provider as? AMSMB2Provider
            let itemPath = item.path
            scrubPrepareTask?.cancel()
            scrubPrepareTask = Task.detached(priority: .userInitiated) {
                let directReader = try? await smbProvider?.openSynchronousScrubReader(at: itemPath)
                await localScrub.prepare(url: streamURL, directReader: directReader)
            }

            let effectiveStartAt = env.settings.enableResumePlayback ? startAt : 0
            try await engine.load(
                url: registered.url,
                fileName: item.name,
                startAt: effectiveStartAt,
                preference: enginePreference
            )
            isLoadingMedia = false

            if engine.activeEngineKind == .avPlayer {
                DisplayModeCoordinator.shared.apply(
                    refreshRate: Float(engine.currentStats().frameRate),
                    formatDescription: engine.avAdapter.videoFormatDescription
                )
            }

            if effectiveStartAt >= 5 {
                showTopNotice("已从 \(formatTime(effectiveStartAt)) 继续播放")
            }

            scheduleHUDHide()
            Task { @MainActor in
                await loadSubtitles(provider: provider, for: item)
            }
        } catch {
            isLoadingMedia = false
            loadError = error.localizedDescription
        }
    }

    private func switchToEpisode(_ item: VFSFileItem) async {
        cancelNextEpisodeCountdown()
        scrubPrepareTask?.cancel()
        scrub.cancelAll()
        if let token = activeStreamToken {
            env.proxy.setScrubMode(false, for: token)
            env.proxy.unregister(token: token)
            activeStreamToken = nil
        }
        await scrubEngine.close()
        scrubEngine = LiveKeyframeScrubEngine()

        currentItem = item
        lastReportedSecond = -1
        availableExternalSubtitles = []
        selectedExternalSubtitlePath = nil
        subtitleTrack = nil
        suppressExternalSubtitle = false
        showHUD = false

        let resumeAt = env.resumePosition(for: request.source.id, filePath: item.path)
        await startPlayback(item: item, startAt: resumeAt)
    }

    private func handlePlaybackEnded() {
        updateIdleTimer()
        guard env.settings.autoPlayNextEpisode, nextEpisode != nil else { return }
        cancelNextEpisodeCountdown()
        nextEpisodeTask = Task { @MainActor in
            for remaining in stride(from: 3, through: 1, by: -1) {
                if Task.isCancelled { return }
                nextEpisodeCountdown = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, let ep = nextEpisode else { return }
            nextEpisodeCountdown = nil
            await switchToEpisode(ep)
        }
    }

    private func cancelNextEpisodeCountdown() {
        nextEpisodeTask?.cancel()
        nextEpisodeTask = nil
        nextEpisodeCountdown = nil
    }

    private func switchEngine(to choice: PreferredEngineChoice) async {
        enginePreference = choice
        guard let url = activeStreamURL else { return }
        let currentPos = engine.currentTime
        showAudioDrawer = false
        do {
            try await engine.load(
                url: url,
                fileName: currentItem.name,
                startAt: currentPos,
                preference: choice
            )
            if engine.activeEngineKind == .avPlayer {
                DisplayModeCoordinator.shared.apply(
                    refreshRate: Float(engine.currentStats().frameRate),
                    formatDescription: engine.avAdapter.videoFormatDescription
                )
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadSubtitles(provider: any VFSProvider, for item: VFSFileItem) async {
        let directory = (item.path as NSString).deletingLastPathComponent
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
                videoFileName: item.name,
                sameDirectoryFiles: sameDir,
                subfolderFiles: folderFiles
            )
            availableExternalSubtitles = candidates
            guard let best = candidates.first else { return }
            await selectExternalSubtitle(best, showBanner: true)
        } catch {
            // Subtitles are optional; playback must never fail because of them.
        }
    }

    private func selectExternalSubtitle(_ candidate: MatchedSubtitleCandidate?, showBanner: Bool = true) async {
        guard let candidate else {
            selectedExternalSubtitlePath = nil
            subtitleTrack = nil
            if showBanner { showTopNotice("已关闭外挂字幕") }
            return
        }
        do {
            let provider: any VFSProvider
            if let existing = activeProvider {
                provider = existing
            } else {
                provider = try await env.connectedProvider(for: request.source)
                activeProvider = provider
            }
            let data = try await provider.readFileData(at: candidate.path, maxBytes: 8 * 1024 * 1024)
            let parsed = SubtitleParser.parse(data: data, fileExtension: candidate.formatExtension)
            selectedExternalSubtitlePath = candidate.path
            subtitleTrack = parsed.track
            suppressExternalSubtitle = false
            if showBanner {
                showTopNotice("已加载外挂字幕：\(candidate.name)")
            }
        } catch {
            showTopNotice("加载字幕失败：\(error.localizedDescription)")
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
            await engine.seek(to: finalTarget, precise: false)
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
            filePath: currentItem.path,
            fileName: currentItem.name,
            lastPositionSeconds: time,
            durationSeconds: engine.duration,
            lastPlayedAt: Date(),
            selectedSubtitlePath: selectedExternalSubtitlePath,
            selectedAudioTrackID: nil
        )
        Task { await env.recordProgress(record) }
    }

    private func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        UIApplication.shared.isIdleTimerDisabled = false
        cancelNextEpisodeCountdown()
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
        engine.onPlaybackEnded = nil
        engine.shutdown()
        DisplayModeCoordinator.shared.reset()
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
