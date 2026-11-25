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
    @AppStorage("auratv.browserLayoutMode") private var layoutModeRaw: String = BrowserLayoutMode.list.rawValue
    @FocusState private var focusedItemID: String?
    @FocusState private var errorFocusTarget: ErrorFocus?

    private let browserHorizontalMargin: CGFloat = 32

    private enum ErrorFocus: Hashable {
        case retry
        case editCredentials
    }

    enum BrowserLayoutMode: String {
        case list
        case grid
    }

    private var layoutMode: BrowserLayoutMode {
        BrowserLayoutMode(rawValue: layoutModeRaw) ?? .list
    }

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
                    .focusSection()
                Divider().opacity(0.25)

                if isLoading {
                    loadingView
                } else if let errorText {
                    errorView(errorText)
                } else if layoutMode == .grid {
                    gridPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, browserHorizontalMargin)
                        .focusSection()
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        listPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .focusSection()

                        detailPane
                            .frame(width: 440)
                    }
                    .padding(.horizontal, browserHorizontalMargin)
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
        HStack(spacing: 16) {
            Button {
                UISoundPlayer.shared.playBack()
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)

            if path != "/" {
                Button {
                    Task { await reload(path: "/") }
                } label: {
                    Label("根目录", systemImage: "house")
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(activeSource.displayName)
                    .font(.system(size: 36, weight: .heavy))
                    .lineLimit(1)
                Text("\(breadcrumb) · \(visibleItems.count) 项")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(TVTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Menu {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { sortMode = mode }
                }
            } label: {
                Label(sortMode.rawValue, systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
            }

            Button {
                layoutModeRaw = (layoutMode == .list ? BrowserLayoutMode.grid : BrowserLayoutMode.list).rawValue
            } label: {
                Label(layoutMode == .list ? "网格" : "列表", systemImage: layoutMode == .list ? "square.grid.2x2" : "list.bullet")
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)

            Button {
                onlyVideos.toggle()
            } label: {
                Label(onlyVideos ? "仅视频" : "全部文件", systemImage: onlyVideos ? "film.fill" : "folder")
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .tint(onlyVideos ? TVTheme.accent : nil)
        }
        .padding(.horizontal, browserHorizontalMargin)
        .padding(.vertical, 16)
    }

    private var breadcrumb: String {
        if path == "/" { return "根目录" }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count <= 3 { return "/" + parts.joined(separator: " / ") }
        return "… / " + parts.suffix(2).joined(separator: " / ")
    }

    private var loadingView: some View {
        VStack(spacing: 22) {
            ProgressView()
                .scaleEffect(1.4)
            Text("正在连接并读取目录…")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(TVTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ errorText: String) -> some View {
        let accountDesc = activeSource.username.isEmpty
            ? "访客登录"
            : "账号 \(activeSource.username)（\(KeychainCredentialStore.hasPassword(forKey: activeSource.credentialKey) ? "已存密码" : "未存密码")）"
        return VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("无法读取目录")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                        Text("\(activeSource.protocolType.rawValue.uppercased()) · \(activeSource.host)\(activeSource.port.map { ":\($0)" } ?? "") · 路径 \(activeSource.basePath) · \(accountDesc)")
                            .font(.system(size: 22))
                            .foregroundStyle(TVTheme.secondaryText)
                    }
                }

                Text(errorText)
                    .font(.system(size: 24))
                    .foregroundStyle(.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(6)

                HStack(spacing: 20) {
                    Button("重试") { Task { await reload(path: path, forceReconnect: true) } }
                        .buttonStyle(.borderedProminent)
                        .font(.system(size: 24, weight: .semibold))
                        .focused($errorFocusTarget, equals: .retry)
                    Button("编辑账号密码") { showCredentialEditor = true }
                        .buttonStyle(.bordered)
                        .font(.system(size: 24, weight: .semibold))
                        .focused($errorFocusTarget, equals: .editCredentials)
                    if path != "/" {
                        Button("回到根目录") { Task { await reload(path: "/") } }
                            .buttonStyle(.bordered)
                            .font(.system(size: 24, weight: .semibold))
                    }
                    Button("返回首页") {
                        UISoundPlayer.shared.playBack()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 24, weight: .semibold))
                }
                .padding(.top, 6)
            }
            .padding(44)
            .frame(maxWidth: 1180, alignment: .leading)
            .tvGlassSurface(cornerRadius: 28)
            .focusSection()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, browserHorizontalMargin)
        .task {
            await Task.yield()
            errorFocusTarget = .editCredentials
        }
    }

    private var listPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if path != "/" {
                    Button {
                        UISoundPlayer.shared.playBack()
                        Task { await goUp() }
                    } label: {
                        row(item: nil, name: "返回上一级", subtitle: "回到上级目录", badges: [], progress: nil)
                    }
                    .buttonStyle(TVListRowButtonStyle())
                }

                if visibleItems.isEmpty && path == "/" {
                    Text("此目录为空")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(TVTheme.tertiaryText)
                        .padding(.vertical, 36)
                        .padding(.horizontal, 24)
                }

                ForEach(visibleItems) { item in
                    let hist = item.isVideo ? env.historyRecord(for: activeSource.id, filePath: item.path) : nil
                    let resumeRatio: Double? = (hist != nil && !hist!.isWatched && hist!.lastPositionSeconds >= 5) ? hist!.progressRatio : nil
                    let subtitleText = itemSubtitle(for: item, history: hist)

                    Button {
                        open(item)
                    } label: {
                        row(
                            item: item,
                            name: item.name,
                            subtitle: subtitleText,
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
            .padding(.vertical, 16)
        }
    }

    private var gridPane: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420, maximum: 460), spacing: 22)], spacing: 22) {
                if path != "/" {
                    Button {
                        UISoundPlayer.shared.playBack()
                        Task { await goUp() }
                    } label: {
                        gridCard(item: nil, name: "返回上一级", subtitle: "回到上级目录", badges: [], progress: nil)
                    }
                    .buttonStyle(TVCardButtonStyle(cornerRadius: 22))
                }

                ForEach(visibleItems) { item in
                    let hist = item.isVideo ? env.historyRecord(for: activeSource.id, filePath: item.path) : nil
                    let resumeRatio: Double? = (hist != nil && !hist!.isWatched && hist!.lastPositionSeconds >= 5) ? hist!.progressRatio : nil
                    let subtitleText = itemSubtitle(for: item, history: hist)
                    let badges = item.isVideo ? Array(VideoBadgeParser.badges(for: item.name).prefix(2)) : []

                    Button {
                        open(item)
                    } label: {
                        gridCard(
                            item: item,
                            name: item.name,
                            subtitle: subtitleText,
                            badges: badges,
                            progress: resumeRatio
                        )
                    }
                    .buttonStyle(TVCardButtonStyle(cornerRadius: 22))
                    .focused($focusedItemID, equals: item.id)
                    .onChange(of: focusedItemID) { _, newValue in
                        if newValue == item.id { focused = item }
                    }
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 6)

            if visibleItems.isEmpty && path == "/" {
                Text("此目录为空")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(TVTheme.tertiaryText)
                    .padding(.vertical, 48)
            }
        }
    }

    private func itemSubtitle(for item: VFSFileItem, history hist: PlaybackHistoryRecord?) -> String {
        if item.isDirectory {
            if let modifiedAt = item.modifiedAt {
                return "文件夹 · \(formatDate(modifiedAt))"
            }
            return "文件夹"
        }
        let sizeStr = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        if let hist, !hist.isWatched, hist.lastPositionSeconds >= 5 {
            return "\(sizeStr) · 上次看到 \(formatTime(hist.lastPositionSeconds))"
        }
        if let modifiedAt = item.modifiedAt {
            return "\(sizeStr) · \(formatDate(modifiedAt))"
        }
        return sizeStr
    }

    @ViewBuilder
    private func itemIconTile(for item: VFSFileItem?, size: CGFloat, cornerRadius: CGFloat, symbolSize: CGFloat) -> some View {
        let isBack = (item == nil)
        let isDir = item?.isDirectory ?? false
        let isVideo = item?.isVideo ?? false
        let isSub = item?.isSubtitle ?? false

        let symbolName: String = {
            if isBack { return "arrow.uturn.backward" }
            if isDir { return "folder.fill" }
            if isVideo { return "film.fill" }
            if isSub { return "captions.bubble.fill" }
            return "doc.fill"
        }()

        let colors: [Color] = {
            if isBack {
                return [Color.white.opacity(0.20), Color.white.opacity(0.10)]
            }
            if isDir {
                return [Color(red: 0.16, green: 0.65, blue: 0.98).opacity(0.90), Color(red: 0.15, green: 0.38, blue: 0.88).opacity(0.90)]
            }
            if isVideo {
                return [Color(red: 0.44, green: 0.36, blue: 0.96).opacity(0.90), Color(red: 0.18, green: 0.56, blue: 0.92).opacity(0.90)]
            }
            return [Color.white.opacity(0.22), Color.white.opacity(0.10)]
        }()

        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbolName)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    private func row(
        item: VFSFileItem?,
        name: String,
        subtitle: String,
        badges: [VideoBadge],
        progress: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                itemIconTile(for: item, size: 66, cornerRadius: 16, symbolSize: 32)

                VStack(alignment: .leading, spacing: 6) {
                    Text(name)
                        .font(.system(size: 32, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(progress != nil ? Color(hex: env.settings.scrubBarColorHex).opacity(0.95) : TVTheme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 16)

                if !badges.isEmpty {
                    BadgeRow(badges: badges)
                }
            }

            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(Color(hex: env.settings.scrubBarColorHex).opacity(0.90))
                            .frame(width: max(0, proxy.size.width * min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 5)
                .padding(.leading, 84)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .contentShape(Rectangle())
    }

    private func gridCard(
        item: VFSFileItem?,
        name: String,
        subtitle: String,
        badges: [VideoBadge],
        progress: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                itemIconTile(for: item, size: 68, cornerRadius: 16, symbolSize: 34)
                Spacer()
                if !badges.isEmpty {
                    BadgeRow(badges: badges)
                }
            }

            Spacer(minLength: 4)

            Text(name)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule()
                            .fill(Color(hex: env.settings.scrubBarColorHex).opacity(0.92))
                            .frame(width: max(0, proxy.size.width * min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 5)
            }

            Text(subtitle)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(progress != nil ? Color(hex: env.settings.scrubBarColorHex).opacity(0.95) : TVTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210, alignment: .topLeading)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let focused {
                HStack(spacing: 18) {
                    itemIconTile(for: focused, size: 108, cornerRadius: 24, symbolSize: 50)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(focused.isDirectory ? "文件夹" : (focused.isVideo ? "视频文件" : "文件"))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(TVTheme.accent)
                        if !focused.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: focused.size, countStyle: .file))
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }

                Text(focused.name)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                if let modifiedAt = focused.modifiedAt {
                    Text("修改时间：\(formatDate(modifiedAt))")
                        .font(.system(size: 22))
                        .foregroundStyle(TVTheme.secondaryText)
                }

                Text(focused.path)
                    .font(.system(size: 20))
                    .foregroundStyle(TVTheme.tertiaryText)
                    .lineLimit(3)

                if !focused.isDirectory,
                   let hist = env.historyRecord(for: activeSource.id, filePath: focused.path),
                   !hist.isWatched, hist.lastPositionSeconds >= 5 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("记忆播放：上次看到 \(formatTime(hist.lastPositionSeconds)) / \(formatTime(hist.durationSeconds))")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color(hex: env.settings.scrubBarColorHex))

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.16))
                                Capsule()
                                    .fill(Color(hex: env.settings.scrubBarColorHex))
                                    .frame(width: max(0, proxy.size.width * min(max(hist.progressRatio, 0), 1)))
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.top, 4)
                }

                let badges = VideoBadgeParser.badges(for: focused.name)
                if !badges.isEmpty {
                    BadgeRow(badges: badges)
                        .padding(.top, 4)
                }

                Spacer()

                Label(focused.isDirectory ? "按确认键进入文件夹" : "按确认键开始播放", systemImage: focused.isDirectory ? "arrow.right.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(TVTheme.secondaryText)
            } else {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.system(size: 46))
                        .foregroundStyle(TVTheme.accent.opacity(0.85))
                    Text("移动焦点以查看文件详情")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(TVTheme.secondaryText)
                }
                Spacer()
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tvGlassSurface(cornerRadius: 24)
        .padding(.vertical, 16)
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

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt
    }()

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
