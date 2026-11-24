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
    var playlist: [VFSFileItem] = []
}

struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var discovery = BonjourDiscoveryService()
    @State private var browserTarget: BrowserTarget?
    @State private var playbackRequest: PlaybackRequest?
    @State private var isAddingSource = false

    private var unaddedDiscoveredHosts: [DiscoveredLANHost] {
        discovery.discoveredHosts.filter { !env.isDiscoveredHostRemembered($0) }
    }

    var body: some View {
        ZStack {
            TVTheme.cinemaBackdrop.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 42) {
                    topBar

                    if env.sources.isEmpty && (!env.settings.enableResumePlayback || env.continueWatching.isEmpty) {
                        emptyHeroCard
                        if !unaddedDiscoveredHosts.isEmpty {
                            discoverySection
                        }
                    } else {
                        if env.settings.enableResumePlayback && !env.continueWatching.isEmpty {
                            continueWatchingSection
                        }

                        if !env.sources.isEmpty {
                            sourcesSection
                        }

                        if !unaddedDiscoveredHosts.isEmpty {
                            discoverySection
                        }
                    }
                }
                .padding(.horizontal, TVMetrics.horizontalSafeMargin)
                .padding(.vertical, TVMetrics.verticalSafeMargin)
            }
        }
        .onAppear { discovery.start() }
        .task { await env.reload() }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $isAddingSource) {
            SourceEditorView(existing: nil)
        }
        .fullScreenCover(item: $browserTarget) { target in
            FileBrowserView(target: target)
        }
        .fullScreenCover(item: $playbackRequest) { request in
            PlayerScreenView(request: request)
        }
    }

    // MARK: - Top Brand Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.22, green: 0.74, blue: 0.97), Color(red: 0.24, green: 0.39, blue: 0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 1.5)
                )
                .shadow(color: Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.35), radius: 12, y: 4)

            Text("AuraTV")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(.white)

            Spacer()

            if !env.sources.isEmpty {
                Button {
                    isAddingSource = true
                } label: {
                    Label("添加服务器", systemImage: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(TVOptionButtonStyle())
            }
        }
    }

    // MARK: - Empty Cinema Hero

    private var emptyHeroCard: some View {
        HStack {
            Spacer()
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [TVTheme.accent.opacity(0.36), .clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 96
                            )
                        )
                        .frame(width: 170, height: 170)

                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.22, green: 0.74, blue: 0.97),
                                    Color(red: 0.31, green: 0.27, blue: 0.90)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 104, height: 104)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 46, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 3)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(.white.opacity(0.42), lineWidth: 1.5)
                        )
                        .shadow(color: TVTheme.accent.opacity(0.35), radius: 24, y: 10)
                }

                VStack(spacing: 10) {
                    Text("连接媒体库")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)

                    Text("SMB · WebDAV · 局域网直连")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }

                Button {
                    isAddingSource = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                        Text("添加服务器")
                            .font(.system(size: 22, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.14, green: 0.62, blue: 0.96), Color(red: 0.25, green: 0.38, blue: 0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                }
                .buttonStyle(TVOptionButtonStyle())
                .padding(.top, 6)
            }
            .padding(.vertical, 54)
            .padding(.horizontal, 80)
            .frame(maxWidth: 920)
            .tvGlassSurface(cornerRadius: 32)
            Spacer()
        }
        .padding(.top, 20)
    }

    // MARK: - Populated Sections

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("继续观看")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(env.continueWatching) { record in
                        Button {
                            replay(record)
                        } label: {
                            ContinueWatchingCard(
                                record: record,
                                barColor: Color(hex: env.settings.scrubBarColorHex)
                            )
                        }
                        .buttonStyle(TVCardButtonStyle(cornerRadius: 24))
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 6)
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("服务器")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 24)], spacing: 24) {
                ForEach(env.sources) { source in
                    Button {
                        browserTarget = BrowserTarget(source: source)
                    } label: {
                        SourceCard(
                            source: source,
                            isConnected: env.connectedSourceIDs.contains(source.id)
                        )
                    }
                    .buttonStyle(TVCardButtonStyle())
                }
            }
        }
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("附近设备")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 20)], spacing: 20) {
                ForEach(unaddedDiscoveredHosts) { host in
                    Button {
                        connectAndRememberDiscovered(host)
                    } label: {
                        HStack(spacing: 16) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                                .frame(width: 56, height: 56)
                                .overlay(
                                    Image(systemName: host.protocolType == "smb" ? "externaldrive.fill" : "globe")
                                        .font(.system(size: 24))
                                        .foregroundStyle(TVTheme.accent)
                                )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(host.serviceName)
                                    .font(.system(size: 22, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(host.protocolType.uppercased()) · \(host.hostName)")
                                    .font(.system(size: 16))
                                    .foregroundStyle(TVTheme.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(20)
                    }
                    .buttonStyle(TVCardButtonStyle(cornerRadius: 20))
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white.opacity(0.92))
    }

    private func connectAndRememberDiscovered(_ host: DiscoveredLANHost) {
        Task {
            let saved = await env.rememberDiscoveredHost(host)
            browserTarget = BrowserTarget(source: saved)
        }
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
        let resumeAt = env.settings.enableResumePlayback ? record.lastPositionSeconds : 0
        playbackRequest = PlaybackRequest(
            source: source,
            item: item,
            resumeAt: resumeAt
        )
    }
}

struct SourceCard: View {
    let source: MediaSourceConfig
    var isConnected: Bool = false

    var body: some View {
        HStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: source.protocolType == .smb
                            ? [Color(red: 0.14, green: 0.62, blue: 0.96).opacity(0.85), Color(red: 0.16, green: 0.36, blue: 0.85).opacity(0.85)]
                            : [Color(red: 0.48, green: 0.36, blue: 0.95).opacity(0.85), Color(red: 0.30, green: 0.22, blue: 0.78).opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: source.protocolType == .smb ? "externaldrive.fill" : "globe")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(source.displayName)
                        .font(.system(size: 25, weight: .semibold))
                        .lineLimit(1)
                    if isConnected {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                    }
                }
                Text("\(source.protocolType.rawValue.uppercased()) · \(source.host)")
                    .font(.system(size: 17))
                    .foregroundStyle(TVTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(height: 124)
    }
}

struct ContinueWatchingCard: View {
    let record: PlaybackHistoryRecord
    var barColor: Color = TVTheme.accent

    private var badges: [VideoBadge] {
        Array(VideoBadgeParser.badges(for: record.fileName).prefix(3))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.13, blue: 0.24),
                    Color(red: 0.05, green: 0.07, blue: 0.13)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [barColor.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 280
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if !badges.isEmpty {
                        BadgeRow(badges: badges)
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()

                Text(record.fileName)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(0, proxy.size.width * min(max(record.progressRatio, 0), 1)))
                    }
                }
                .frame(height: 4)

                Text("剩余 \(formatted(record.remainingSeconds))")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(TVTheme.secondaryText)
            }
            .padding(22)
        }
        .frame(width: 420, height: 236)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h) 小时 \(m) 分" : "\(max(1, m)) 分钟"
    }
}
