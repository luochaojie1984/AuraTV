import SwiftUI
import NetworkVFS

struct SourceListView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var editingSource: MediaSourceConfig?
    @State private var isAdding = false
    @State private var browserTarget: BrowserTarget?
    @State private var speedTestSource: MediaSourceConfig?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("网络源")
                        .font(.system(size: 44, weight: .heavy))
                    Spacer()
                    Button {
                        isAdding = true
                    } label: {
                        Label("添加 SMB / WebDAV", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if env.sources.isEmpty {
                    Text("尚未添加任何网络源。")
                        .font(.system(size: 22))
                        .foregroundStyle(TVTheme.tertiaryText)
                        .padding(.vertical, 30)
                }

                ForEach(env.sources) { source in
                    HStack(spacing: 20) {
                        Button {
                            browserTarget = BrowserTarget(source: source)
                        } label: {
                            SourceCard(source: source, isConnected: env.connectedSourceIDs.contains(source.id))
                        }
                        .buttonStyle(TVCardButtonStyle())

                        VStack(spacing: 12) {
                            Button("编辑") { editingSource = source }
                                .buttonStyle(.bordered)
                            Button("测速") { speedTestSource = source }
                                .buttonStyle(.bordered)
                            Button("删除", role: .destructive) {
                                Task { try? await env.delete(source: source) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(.horizontal, TVMetrics.horizontalSafeMargin)
            .padding(.vertical, TVMetrics.verticalSafeMargin)
        }
        .sheet(isPresented: $isAdding) {
            SourceEditorView(existing: nil)
        }
        .sheet(item: $editingSource) { source in
            SourceEditorView(existing: source)
        }
        .fullScreenCover(item: $browserTarget) { target in
            FileBrowserView(target: target)
        }
        .sheet(item: $speedTestSource) { source in
            SpeedTestView(source: source)
        }
    }
}

struct SourceEditorView: View {
    let existing: MediaSourceConfig?

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var protocolType: MediaSourceProtocol = .smb
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var basePath: String = "/"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var useTLS = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(existing == nil ? "添加网络源" : "编辑网络源")
                    .font(.system(size: 36, weight: .bold))

                field("名称", text: $displayName, placeholder: "客厅 NAS")

                HStack(spacing: 16) {
                    Text("协议").font(.system(size: 19)).frame(width: 150, alignment: .leading)
                    Button("SMB") { protocolType = .smb }
                        .buttonStyle(.bordered)
                        .tint(protocolType == .smb ? TVTheme.accent : .gray)
                    Button("WebDAV") { protocolType = .webdav }
                        .buttonStyle(.bordered)
                        .tint(protocolType == .webdav ? TVTheme.accent : .gray)
                }

                field("主机 / IP", text: $host, placeholder: "192.168.5.229")
                field("端口（留空用默认）", text: $port, placeholder: protocolType == .smb ? "445" : "80")
                field("路径 / 共享名", text: $basePath, placeholder: "/AV 或 /Movies")
                field("用户名", text: $username, placeholder: "guest")
                field("密码", text: $password, placeholder: "仅存 Keychain")

                if protocolType == .webdav {
                    Toggle("使用 HTTPS", isOn: $useTLS)
                }

                if let errorText {
                    Text(errorText).foregroundStyle(.orange)
                }

                HStack(spacing: 16) {
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                    Button("取消") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 10)
            }
            .padding(50)
        }
        .onAppear(perform: load)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 19))
                .frame(width: 210, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func load() {
        guard let existing else { return }
        displayName = existing.displayName
        protocolType = existing.protocolType
        host = existing.host
        port = existing.port.map(String.init) ?? ""
        basePath = existing.basePath
        username = existing.username
        useTLS = existing.useTLS
    }

    private func save() {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorText = "主机地址不能为空"
            return
        }
        let config = MediaSourceConfig(
            id: existing?.id ?? UUID(),
            displayName: displayName.isEmpty ? host : displayName,
            protocolType: protocolType,
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port),
            useTLS: useTLS,
            basePath: basePath.isEmpty ? "/" : basePath,
            username: username,
            credentialKey: existing?.credentialKey ?? ""
        )
        Task {
            do {
                try await env.upsert(source: config, password: password.isEmpty ? nil : password)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

struct SpeedTestView: View {
    let source: MediaSourceConfig
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var resultMbps: Double?
    @State private var sampleName: String?
    @State private var isRunning = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 22) {
            Text("局域网测速 · \(source.displayName)")
                .font(.system(size: 30, weight: .bold))

            if isRunning {
                ProgressView("正在读取 20 MB 样本…")
            } else if let mbps = resultMbps {
                Text(String(format: "%.1f Mbps", mbps))
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(mbps >= 300 ? .green : (mbps >= 100 ? .yellow : .orange))
                Text(mbps >= 300 ? "足够流畅播放 4K 蓝光原盘" : (mbps >= 100 ? "可流畅播放 1080p 高码率" : "码率偏低，4K 原盘可能卡顿"))
                    .font(.system(size: 20))
                    .foregroundStyle(TVTheme.secondaryText)
                if let sampleName {
                    Text("样本：\(sampleName)").font(.system(size: 16)).foregroundStyle(TVTheme.tertiaryText)
                }
            } else if let errorText {
                Text(errorText).foregroundStyle(.orange)
            }

            HStack(spacing: 16) {
                Button("开始测速") { Task { await run() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(50)
    }

    private func run() async {
        guard let provider = env.makeProvider(for: source) else {
            errorText = "无法创建连接器"
            return
        }
        isRunning = true
        errorText = nil
        defer { isRunning = false }
        do {
            try await provider.connect()
            let entries = try await provider.listDirectory(at: source.basePath)
            guard let sample = entries.first(where: { !$0.isDirectory && $0.size > 0 }) else {
                errorText = "目录里没有可读取的文件"
                return
            }
            sampleName = sample.name
            resultMbps = try await provider.benchmarkThroughput(at: sample.path, sampleBytes: 20 * 1024 * 1024)
            await provider.disconnect()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
