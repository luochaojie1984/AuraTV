import SwiftUI
import NetworkVFS
import AppPreferences

struct FileBrowserView: View {
    let target: BrowserTarget

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var activeSource: MediaSourceConfig
    @State private var items: [VFSFileItem] = []
    @State private var path: String = "/"
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var focused: VFSFileItem?
    @State private var onlyVideos = false
    @State private var sortMode: SortMode = .name
    @State private var playbackRequest: PlaybackRequest?
    @State private var showCredentialEditor = false
    @FocusState private var focusedItemID: String?

    init(target: BrowserTarget) {
        self.target = target
        self._activeSource = State(initialValue: target.source)
    }

    enum SortMode: String, CaseIterable {
        case name = "名称"
        case modified = "修改时间"
        case size = "大小"
    }

    private var visibleItems: [VFSFileItem] {
        var list = items
        if onlyVideos {
            list = list.filter { $0.isDirectory || $0.isVideo }
        }
        switch sortMode {
        case .name:
            list.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .modified:
            list.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }
        case .size:
            list.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.size > rhs.size
            }
        }
        return list
    }

    var body: some View {
        ZStack {
            TVTheme.cinemaBackdrop.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider().opacity(0.25)

                HStack(alignment: .top, spacing: 0) {
                    listPane
                        .frame(maxWidth: .infinity, alignment: .leading)

                    detailPane
                        .frame(width: 520)
                }
            }
        }
        .task { await boot() }
        .onExitCommand {
            UISoundPlayer.shared.playBack()
            if path != "/" {
                Task { await goUp() }
            } else {
                dismiss()
            }
        }
        .fullScreenCover(item: $playbackRequest) { req in
            PlayerScreenView(request: req)
        }
        .sheet(isPresented: $showCredentialEditor, onDismiss: {
            Task {
                if let updated = env.sources.first(where: { $0.id == activeSource.id }) {
                    activeSource = updated
                }
                await reload(path: path, forceReconnect: true)
            }
        }) {
            SourceEditorView(existing: activeSource)
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button {
                UISoundPlayer.shared.playBack()
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)

            if path != "/" {
                Button {
                    Task { await reload(path: "/") }
                } label: {
                    Label("根目录", systemImage: "house")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(activeSource.displayName)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1)
                Text(breadcrumb)
                    .font(.system(size: 17))
                    .foregroundStyle(TVTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Menu(sortMode.rawValue) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { sortMode = mode }
                }
            }

            Toggle("仅视频", isOn: $onlyVideos)
                .frame(width: 190)
        }
        .padding(.horizontal, TVMetrics.horizontalSafeMargin)
        .padding(.vertical, 26)
    }

    private var breadcrumb: String {
        if path == "/" { return "根目录" }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count <= 3 { return "/" + parts.joined(separator: " / ") }
        return "… / " + parts.suffix(2).joined(separator: " / ")
    }

    private var listPane: some View {
        ScrollView {
            if isLoading {
                ProgressView("正在读取目录…").padding(60)
            } else if let errorText {
                VStack(alignment: .leading, spacing: 16) {
                    Text(errorText)
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                    HStack(spacing: 16) {
                        Button("重试") { Task { await reload(path: path, forceReconnect: true) } }
                            .buttonStyle(.borderedProminent)
                        Button("编辑账号密码") { showCredentialEditor = true }
                            .buttonStyle(.bordered)
                        if path != "/" {
                            Button("回到根目录") { Task { await reload(path: "/") } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(60)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if path != "/" {
                        Button {
                            UISoundPlayer.shared.playBack()
                            Task { await goUp() }
                        } label: {
                            row(id: "up", name: "⬅︎ 上一级", subtitle: "", isDir: true, badges: [], progress: nil)
                        }
                        .buttonStyle(TVListRowButtonStyle())
                    }
                    ForEach(visibleItems) { item in
                        let hist = item.isVideo ? env.historyRecord(for: activeSource.id, filePath: item.path) : nil
                        let resumeRatio: Double? = (hist != nil && !hist!.isWatched && hist!.lastPositionSeconds >= 5) ? hist!.progressRatio : nil
                        let subtitleText: String = {
                            if item.isDirectory { return "文件夹" }
                            let sizeStr = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
                            if let hist, !hist.isWatched, hist.lastPositionSeconds >= 5 {
                                return "\(sizeStr) · 上次看到 \(formatTime(hist.lastPositionSeconds))"
                            }
                            return sizeStr
                        }()

                        Button {
                            open(item)
                        } label: {
                            row(
                                id: item.id,
                                name: item.name,
                                subtitle: subtitleText,
                                isDir: item.isDirectory,
                                badges: item.isVideo ? VideoBadgeParser.badges(for: item.name) : [],
                                progress: resumeRatio
                            )
                        }
                        .buttonStyle(TVListRowButtonStyle())
                        .focused($focusedItemID, equals: item.id)
                        .onChange(of: focusedItemID) { _, newValue in
                            if newValue == item.id { focused = item }
                        }
                    }
                }
                .padding(.horizontal, TVMetrics.horizontalSafeMargin)
                .padding(.vertical, 16)
            }
        }
    }

    private func row(
        id: String,
        name: String,
        subtitle: String,
        isDir: Bool,
        badges: [VideoBadge],
        progress: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Image(systemName: isDir ? "folder.fill" : "film.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(isDir ? TVTheme.accent : .white.opacity(0.75))
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 24, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 16))
                            .foregroundStyle(progress != nil ? Color(hex: env.settings.scrubBarColorHex).opacity(0.9) : TVTheme.tertiaryText)
                    }
                }

                Spacer()

                if !badges.isEmpty {
                    BadgeRow(badges: badges)
                }
            }

            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(Color(hex: env.settings.scrubBarColorHex).opacity(0.85))
                            .frame(width: max(0, proxy.size.width * min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 3)
                .padding(.leading, 48)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("详情")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(TVTheme.secondaryText)

            if let focused {
                Text(focused.name)
                    .font(.system(size: 26, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(focused.path)
                    .font(.system(size: 16))
                    .foregroundStyle(TVTheme.tertiaryText)
                if !focused.isDirectory {
                    Text("大小：\(ByteCountFormatter.string(fromByteCount: focused.size, countStyle: .file))")
                        .font(.system(size: 18))
                        .foregroundStyle(TVTheme.secondaryText)
                    if let hist = env.historyRecord(for: activeSource.id, filePath: focused.path),
                       !hist.isWatched, hist.lastPositionSeconds >= 5 {
                        Text("记忆播放：上次看到 \(formatTime(hist.lastPositionSeconds)) / \(formatTime(hist.durationSeconds))")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color(hex: env.settings.scrubBarColorHex))
                    }
                }
                if !VideoBadgeParser.badges(for: focused.name).isEmpty {
                    BadgeRow(badges: VideoBadgeParser.badges(for: focused.name))
                }
            } else {
                Text("移动焦点以查看文件详情")
                    .font(.system(size: 18))
                    .foregroundStyle(TVTheme.tertiaryText)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .tvGlassSurface(cornerRadius: 22)
        .padding(.trailing, TVMetrics.horizontalSafeMargin)
        .padding(.vertical, 20)
    }

    private func boot() async {
        let remembered = env.lastVisitedPath(for: activeSource.id)
        await reload(path: remembered)
        if errorText != nil && remembered != "/" {
            // Remembered subfolder may have been renamed/deleted -> gracefully fall back to root
            await reload(path: "/")
        }
    }

    private func reload(path newPath: String, forceReconnect: Bool = false) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let provider = try await env.connectedProvider(for: activeSource, forceReconnect: forceReconnect)
            do {
                items = try await provider.listDirectory(at: newPath)
            } catch {
                // Retry once after transparent reconnect (handles idle NAS SMB timeout)
                let fresh = try await env.connectedProvider(for: activeSource, forceReconnect: true)
                items = try await fresh.listDirectory(at: newPath)
            }
            path = newPath
            focused = nil
            env.rememberVisitedPath(newPath, for: activeSource.id)
        } catch {
            errorText = "连接或读取目录失败：\(error.localizedDescription)"
        }
    }

    private func goUp() async {
        guard path != "/" else { return }
        var parts = path.split(separator: "/").map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        let parent = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
        await reload(path: parent)
    }

    private func open(_ item: VFSFileItem) {
        if item.isDirectory {
            Task { await reload(path: item.path) }
        } else if item.isVideo {
            let resumeAt = env.resumePosition(for: activeSource.id, filePath: item.path)
            let episodes = visibleItems.filter(\.isVideo)
            playbackRequest = PlaybackRequest(
                source: activeSource,
                item: item,
                resumeAt: resumeAt,
                playlist: episodes
            )
        }
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
