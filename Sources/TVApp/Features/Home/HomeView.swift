import SwiftUI
import NetworkVFS
import AppPreferences

struct BrowserTarget: Identifiable {
    let id = UUID()
    let source: MediaSourceConfig
}

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let source: MediaSourceConfig
    let item: VFSFileItem
    let resumeAt: TimeInterval
}

struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var discovery = BonjourDiscoveryService()
    @State private var browserTarget: BrowserTarget?
    @State private var playbackRequest: PlaybackRequest?
    @State private var editingSource: MediaSourceConfig?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header

                if !env.continueWatching.isEmpty {
                    continueWatchingSection
                }

                sourcesSection
                discoverySection
            }
            .padding(.horizontal, TVMetrics.horizontalSafeMargin)
            .padding(.vertical, TVMetrics.verticalSafeMargin)
        }
        .onAppear {
            env.reload()
            discovery.start()
        }
        .onDisappear { discovery.stop() }
        .fullScreenCover(item: $browserTarget) { target in
            FileBrowserView(target: target, onPlay: { request in
                browserTarget = nil
                playbackRequest = request
            })
        }
        .fullScreenCover(item: $playbackRequest) { request in
            PlayerScreenView(request: request)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AuraTV")
                .font(.system(size: 64, weight: .heavy))
                .foregroundStyle(.white)
            Text("局域网影视库 · SMB / WebDAV · 原生 HDR 与 MX 长按快进")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(TVTheme.secondaryText)
        }
    }

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("继续观看")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(env.continueWatching) { record in
                        Button {
                            replay(record)
                        } label: {
                            ContinueWatchingCard(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("我的网络源")
            if env.sources.isEmpty {
                Text("还没有网络源。按「网络源」标签页添加 SMB 或 WebDAV，或在下方局域网发现里一键添加。")
                    .font(.system(size: 22))
                    .foregroundStyle(TVTheme.tertiaryText)
                    .padding(.vertical, 18)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 22)], spacing: 22) {
                    ForEach(env.sources) { source in
                        Button {
                            browserTarget = BrowserTarget(source: source)
                        } label: {
                            SourceCard(source: source)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("局域网发现")
            if discovery.discoveredHosts.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(discovery.isBrowsing ? "正在通过 Bonjour 搜索局域网设备…" : "未启动发现")
                        .font(.system(size: 20))
                        .foregroundStyle(TVTheme.tertiaryText)
                }
                .padding(.vertical, 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 18)], spacing: 18) {
                    ForEach(discovery.discoveredHosts) { host in
                        Button {
                            addDiscovered(host)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: host.protocolType == "smb" ? "externaldrive.fill" : "network")
                                    .font(.system(size: 26))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(host.serviceName)
                                        .font(.system(size: 22, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(host.hostName):\(host.port) · \(host.protocolType.uppercased())")
                                        .font(.system(size: 17))
                                        .foregroundStyle(TVTheme.secondaryText)
                                }
                                Spacer()
                            }
                            .padding(18)
                            .tvGlassSurface(cornerRadius: 18)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
    }

    private func addDiscovered(_ host: DiscoveredLANHost) {
        let config = MediaSourceConfig(
            displayName: host.serviceName,
            protocolType: host.protocolType == "smb" ? .smb : .webdav,
            host: host.hostName,
            port: host.port,
            useTLS: host.protocolType == "webdav" && host.port == 443,
            basePath: "/"
        )
        try? env.upsert(source: config, password: nil)
    }

    private func replay(_ record: PlaybackHistoryRecord) {
        guard let source = env.sources.first(where: { $0.id == record.sourceID }) else { return }
        let item = VFSFileItem(
            id: record.filePath,
            name: record.fileName,
            path: record.filePath,
            isDirectory: false,
            size: 0,
            modifiedAt: record.lastPlayedAt
        )
        playbackRequest = PlaybackRequest(
            source: source,
            item: item,
            resumeAt: record.lastPositionSeconds
        )
    }
}

struct SourceCard: View {
    let source: MediaSourceConfig
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: source.protocolType == .smb ? "externaldrive.fill" : "globe.asia.australia.fill")
                .font(.system(size: 40))
                .foregroundStyle(TVTheme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(source.displayName)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                Text("\(source.protocolType.rawValue.uppercased()) · \(source.host)\(source.port.map { ":\($0)" } ?? "")")
                    .font(.system(size: 18))
                    .foregroundStyle(TVTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(22)
        .frame(height: 118)
        .tvCardFocus(focused)
        .focused($focused)
    }
}

struct ContinueWatchingCard: View {
    let record: PlaybackHistoryRecord
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(record.fileName)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(2)
                .frame(width: 360, height: 62, alignment: .leading)
            ProgressView(value: min(max(record.progressRatio, 0), 1))
                .tint(TVTheme.accent)
                .frame(width: 360)
            Text("剩余 \(formatted(record.remainingSeconds))")
                .font(.system(size: 16))
                .foregroundStyle(TVTheme.tertiaryText)
        }
        .padding(18)
        .frame(width: 396)
        .tvCardFocus(focused)
        .focused($focused)
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h) 小时 \(m) 分" : "\(m) 分"
    }
}
