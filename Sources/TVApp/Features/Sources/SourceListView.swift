import SwiftUI
import NetworkVFS

struct SourceListView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var editingSource: MediaSourceConfig?
    @State private var isAdding = false
    @State private var pendingOpenSource: MediaSourceConfig?
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
        .sheet(isPresented: $isAdding, onDismiss: {
            if let source = pendingOpenSource {
                pendingOpenSource = nil
                browserTarget = BrowserTarget(source: source)
            }
        }) {
            SourceEditorView(existing: nil) { saved in
                pendingOpenSource = saved
            }
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
    var onSaved: ((MediaSourceConfig) -> Void)? = nil

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var protocolType: MediaSourceProtocol = .smb
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var basePath: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var useTLS = false
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(existing == nil ? "添加服务器" : "编辑服务器")
                    .font(.system(size: 32, weight: .bold))

                field("名称", text: $displayName, placeholder: "留空则自动使用主机名")

                HStack(spacing: 16) {
                    Text("协议")
                        .font(.system(size: 19))
                        .frame(width: 210, alignment: .leading)
                    Button("SMB") { protocolType = .smb }
                        .buttonStyle(.bordered)
                        .tint(protocolType == .smb ? TVTheme.accent : .gray)
                    Button("WebDAV") { protocolType = .webdav }
                        .buttonStyle(.bordered)
                        .tint(protocolType == .webdav ? TVTheme.accent : .gray)
                }

                field("主机 / IP", text: $host, placeholder: "输入局域网 IP 或主机名", disableAutocorrect: true)
                field(
                    "端口（留空默认）",
                    text: $port,
                    placeholder: protocolType == .smb ? "默认 445" : (useTLS ? "默认 443" : "默认 80"),
                    disableAutocorrect: true
                )
                field("路径 / 共享名", text: $basePath, placeholder: "留空则浏览全部共享", disableAutocorrect: true)
                field("用户名", text: $username, placeholder: "留空则访客登录", disableAutocorrect: true)
                secureField(
                    "密码",
                    text: $password,
                    placeholder: existing == nil ? "输入密码（留空则无密码）" : "留空则保留原密码"
                )

                if protocolType == .webdav {
                    Toggle("使用 HTTPS", isOn: $useTLS)
                }

                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 16) {
                    Button(existing == nil ? "保存并进入" : "保存") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                    Button("取消") { dismiss() }
                        .buttonStyle(.bordered)
                        .disabled(isSaving)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 48)
            .padding(.top, 44)
            .padding(.bottom, 32)
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func field(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        disableAutocorrect: Bool = false
    ) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 19))
                .frame(width: 210, alignment: .leading)
            if disableAutocorrect {
                TextField(placeholder, text: text)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
            } else {
                TextField(placeholder, text: text)
            }
        }
    }

    private func secureField(
        _ title: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 19))
                .frame(width: 210, alignment: .leading)
            SecureField(placeholder, text: text)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
        }
    }

    private func load() {
        guard let existing else { return }
        displayName = existing.displayName
        protocolType = existing.protocolType
        host = existing.host
        port = existing.port.map(String.init) ?? ""
        basePath = existing.basePath == "/" ? "" : existing.basePath
        username = existing.username
        useTLS = existing.useTLS
    }

    private func save() {
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var effectiveUseTLS = useTLS
        let lowerHost = cleanHost.lowercased()
        if lowerHost.hasPrefix("smb://") {
            cleanHost = String(cleanHost.dropFirst("smb://".count))
        } else if lowerHost.hasPrefix("https://") {
            cleanHost = String(cleanHost.dropFirst("https://".count))
            if protocolType == .webdav {
                effectiveUseTLS = true
            }
        } else if lowerHost.hasPrefix("http://") {
            cleanHost = String(cleanHost.dropFirst("http://".count))
        }
        while cleanHost.hasSuffix("/") {
            cleanHost.removeLast()
        }
        cleanHost = cleanHost.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanHost.isEmpty else {
            errorText = "主机地址不能为空"
            return
        }

        let cleanPortText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort: Int?
        if cleanPortText.isEmpty {
            parsedPort = nil
        } else if let value = Int(cleanPortText), (1...65535).contains(value) {
            parsedPort = value
        } else {
            errorText = "端口号无效"
            return
        }

        let cleanDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBasePath = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBasePath: String
        if trimmedBasePath.isEmpty {
            normalizedBasePath = "/"
        } else {
            var withLeading = trimmedBasePath.hasPrefix("/") ? trimmedBasePath : "/" + trimmedBasePath
            while withLeading.count > 1 && withLeading.hasSuffix("/") {
                withLeading.removeLast()
            }
            normalizedBasePath = withLeading
        }

        let config = MediaSourceConfig(
            id: existing?.id ?? UUID(),
            displayName: cleanDisplayName.isEmpty ? cleanHost : cleanDisplayName,
            protocolType: protocolType,
            host: cleanHost,
            port: parsedPort,
            useTLS: protocolType == .webdav ? effectiveUseTLS : false,
            basePath: normalizedBasePath,
            username: cleanUsername,
            credentialKey: existing?.credentialKey ?? ""
        )

        isSaving = true
        errorText = nil
        Task {
            do {
                try await env.upsert(source: config, password: password.isEmpty ? nil : password)
                onSaved?(config)
                dismiss()
            } catch {
                isSaving = false
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
