import SwiftUI
import NetworkVFS

struct FileBrowserView: View {
    let target: BrowserTarget
    let onPlay: (PlaybackRequest) -> Void

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var provider: (any VFSProvider)?
    @State private var items: [VFSFileItem] = []
    @State private var path: String = "/"
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var focused: VFSFileItem?
    @State private var onlyVideos = false
    @State private var sortMode: SortMode = .name

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
            TVTheme.backdrop.ignoresSafeArea()

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
        .onDisappear {
            if let provider {
                Task { await provider.disconnect() }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: {
                Label("返回", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 4) {
                Text(target.source.displayName)
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
                VStack(alignment: .leading, spacing: 14) {
                    Text(errorText)
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                    Button("重试") { Task { await reload(path: path) } }
                }
                .padding(60)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if path != "/" {
                        Button {
                            Task { await goUp() }
                        } label: {
                            row(id: "up", name: "⬅︎ 上一级", subtitle: "", isDir: true, badges: [], progress: nil)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(visibleItems) { item in
                        Button {
                            open(item)
                        } label: {
                            row(
                                id: item.id,
                                name: item.name,
                                subtitle: item.isDirectory ? "文件夹" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file),
                                isDir: item.isDirectory,
                                badges: item.isVideo ? VideoBadgeParser.badges(for: item.name) : [],
                                progress: nil
                            )
                        }
                        .buttonStyle(.plain)
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

    @FocusState private var focusedItemID: String?

    private func row(
        id: String,
        name: String,
        subtitle: String,
        isDir: Bool,
        badges: [VideoBadge],
        progress: Double?
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: isDir ? "folder.fill" : "film.fill")
                .font(.system(size: 24))
                .foregroundStyle(isDir ? TVTheme.accent : .white.opacity(0.7))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 24, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(TVTheme.tertiaryText)
                }
            }

            Spacer()

            if !badges.isEmpty {
                BadgeRow(badges: badges)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(focusedItemID == id ? TVTheme.cardFocused : Color.clear)
        )
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
                    .textSelection(.enabled)
                if !focused.isDirectory {
                    Text("大小：\(ByteCountFormatter.string(fromByteCount: focused.size, countStyle: .file))")
                        .font(.system(size: 18))
                        .foregroundStyle(TVTheme.secondaryText)
                }
                if !VideoBadgeParser.badges(for: focused.name).isEmpty {
                    BadgeRow(badges: VideoBadgeParser.badges(for: focused.name))
                }
            } else {
                Text("把遥控器移到左侧条目上查看完整文件名与路径（超长中日文不截断）。")
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
        let newProvider = env.makeProvider(for: target.source)
        provider = newProvider
        guard let newProvider else {
            errorText = "无法创建该源的连接器"
            return
        }
        do {
            try await newProvider.connect()
            await reload(path: "/")
        } catch {
            errorText = "连接失败：\(error.localizedDescription)"
        }
    }

    private func reload(path newPath: String) async {
        guard let provider else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            items = try await provider.listDirectory(at: newPath)
            path = newPath
            focused = nil
        } catch {
            errorText = "读取目录失败：\(error.localizedDescription)"
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
            onPlay(
                PlaybackRequest(
                    source: target.source,
                    item: item,
                    resumeAt: 0
                )
            )
        }
    }
}
