import SwiftUI
import AppPreferences
import SubtitleKit

struct AppSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var clearedNotice = false

    private let barOpacityPresets: [(String, Double)] = [
        ("30% 极淡", 0.30),
        ("50% 半透", 0.50),
        ("65% 推荐", 0.65),
        ("85% 清晰", 0.85),
        ("100% 不透", 1.00)
    ]

    private let barHeightPresets: [(String, Double)] = [
        ("4pt 极扁", 4.0),
        ("5pt 推荐", 5.0),
        ("8pt 加粗", 8.0)
    ]

    private let timeOpacityPresets: [(String, Double)] = [
        ("45% 极浅", 0.45),
        ("72% 浅色推荐", 0.72),
        ("90% 清晰", 0.90)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("设置")
                    .font(.system(size: 44, weight: .heavy))

                // 1. 快进与快退
                group("快进与快退") {
                    // 5 秒为单位自由增减短按步长
                    HStack(spacing: 14) {
                        Text("短按左/右键步长")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 220, alignment: .leading)

                        Button {
                            let next = max(5.0, env.settings.shortSeekSeconds - 5.0)
                            Task { await env.updateSettings { $0.shortSeekSeconds = next } }
                        } label: {
                            Text("− 5s")
                                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(TVOptionButtonStyle())
                        .disabled(env.settings.shortSeekSeconds <= 5)

                        Text("\(Int(env.settings.shortSeekSeconds)) 秒")
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(TVTheme.accent)
                            .frame(width: 96)

                        Button {
                            let next = min(120.0, env.settings.shortSeekSeconds + 5.0)
                            Task { await env.updateSettings { $0.shortSeekSeconds = next } }
                        } label: {
                            Text("+ 5s")
                                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(TVOptionButtonStyle())
                        .disabled(env.settings.shortSeekSeconds >= 120)

                        Spacer().frame(width: 12)

                        ForEach([5.0, 10.0, 15.0, 20.0, 30.0, 60.0], id: \.self) { val in
                            let selected = Int(env.settings.shortSeekSeconds) == Int(val)
                            Button {
                                Task { await env.updateSettings { $0.shortSeekSeconds = val } }
                            } label: {
                                Text("\(Int(val))s")
                                    .font(.system(size: 16, weight: selected ? .bold : .regular))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        selected ? TVTheme.accent.opacity(0.45) : Color.white.opacity(0.08),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(TVOptionButtonStyle())
                        }
                        Spacer()
                    }

                    optionRow(
                        title: "短按方向键模式",
                        options: ["定长跳秒 (推荐)", "多级实时加速 4x~64x"],
                        selectedIndex: env.settings.shortPressSeekBehavior == .fixedStepJump ? 0 : 1
                    ) { index in
                        Task {
                            await env.updateSettings {
                                $0.shortPressSeekBehavior = index == 0 ? .fixedStepJump : .multiStageShuttle
                            }
                        }
                    }

                    optionRow(
                        title: "长按快进方式",
                        options: ["MX 实时出画 (推荐)", "连续 3x 倍速"],
                        selectedIndex: env.settings.longPressSeekMode == .mxLiveKeyframeScrub ? 0 : 1
                    ) { index in
                        Task {
                            await env.updateSettings {
                                $0.longPressSeekMode = index == 0 ? .mxLiveKeyframeScrub : .continuousFastPlay
                            }
                        }
                    }

                    if env.settings.longPressSeekMode == .mxLiveKeyframeScrub {
                        optionRow(
                            title: "长按快进速度",
                            options: LongPressSpeedProfile.allCases.map(\.displayName),
                            selectedIndex: LongPressSpeedProfile.allCases.firstIndex(of: env.settings.longPressSpeedProfile) ?? 1
                        ) { index in
                            let choice = LongPressSpeedProfile.allCases[index]
                            Task { await env.updateSettings { $0.longPressSpeedProfile = choice } }
                        }
                    }

                    optionRow(
                        title: "触控板左右划屏",
                        options: ["开启 (推荐)", "关闭"],
                        selectedIndex: env.settings.enableTouchpadScrub ? 0 : 1
                    ) { index in
                        Task { await env.updateSettings { $0.enableTouchpadScrub = (index == 0) } }
                    }
                }

                // 2. 快进进度条外观（仿 MX Player，附实时预览）
                group("快进进度条样式（底部透明扁平条）") {
                    scrubBarPreview

                    // 进度条高亮颜色
                    HStack(spacing: 14) {
                        Text("播放位置颜色")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 220, alignment: .leading)

                        ForEach(ScrubBarColorPreset.allCases, id: \.self) { preset in
                            let selected = env.settings.scrubBarColorHex.caseInsensitiveCompare(preset.rawValue) == .orderedSame
                            Button {
                                Task { await env.updateSettings { $0.scrubBarColorHex = preset.rawValue } }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(hex: preset.rawValue))
                                        .frame(width: 18, height: 18)
                                    Text(preset.displayName)
                                        .font(.system(size: 16, weight: selected ? .bold : .regular))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    selected ? Color(hex: preset.rawValue).opacity(0.32) : Color.white.opacity(0.08),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(TVOptionButtonStyle())
                        }
                        Spacer()
                    }

                    optionRow(
                        title: "进度条透明度",
                        options: barOpacityPresets.map(\.0),
                        selectedIndex: closestIndex(env.settings.scrubBarOpacity, in: barOpacityPresets.map(\.1))
                    ) { index in
                        let val = barOpacityPresets[index].1
                        Task { await env.updateSettings { $0.scrubBarOpacity = val } }
                    }

                    optionRow(
                        title: "进度条粗细",
                        options: barHeightPresets.map(\.0),
                        selectedIndex: closestIndex(env.settings.scrubBarHeight, in: barHeightPresets.map(\.1))
                    ) { index in
                        let val = barHeightPresets[index].1
                        Task { await env.updateSettings { $0.scrubBarHeight = val } }
                    }

                    optionRow(
                        title: "进度条时间文字",
                        options: ["显示 (浅色无底框)", "不显示 (仅保留底部细条)"],
                        selectedIndex: env.settings.showScrubTimeText ? 0 : 1
                    ) { index in
                        Task { await env.updateSettings { $0.showScrubTimeText = (index == 0) } }
                    }

                    if env.settings.showScrubTimeText {
                        optionRow(
                            title: "时间文字浅淡度",
                            options: timeOpacityPresets.map(\.0),
                            selectedIndex: closestIndex(env.settings.scrubTimeTextOpacity, in: timeOpacityPresets.map(\.1))
                        ) { index in
                            let val = timeOpacityPresets[index].1
                            Task { await env.updateSettings { $0.scrubTimeTextOpacity = val } }
                        }
                    }
                }

                // 3. 记忆播放（断点续播）
                group("记忆播放（断点续播）") {
                    optionRow(
                        title: "自动记忆播放位置",
                        options: ["开启 (推荐)", "关闭"],
                        selectedIndex: env.settings.enableResumePlayback ? 0 : 1
                    ) { index in
                        Task { await env.updateSettings { $0.enableResumePlayback = (index == 0) } }
                    }

                    HStack(spacing: 18) {
                        Text("已记忆影片：\(env.historyByKey.count) 部")
                            .font(.system(size: 17))
                            .foregroundStyle(TVTheme.secondaryText)

                        Button(role: .destructive) {
                            Task {
                                await env.clearPlaybackHistory()
                                clearedNotice = true
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                clearedNotice = false
                            }
                        } label: {
                            Text(clearedNotice ? "已清空" : "清空全部播放记忆")
                        }
                        .buttonStyle(.bordered)
                        .disabled(env.historyByKey.isEmpty)
                    }

                    Text("开启后，不论是从首页「继续观看」还是在文件夹内再次打开影片，都会自动从上次看到的位置继续播放（看完 95% 以上自动重头播）；关闭后每次均从 00:00 开始。")
                        .font(.system(size: 16))
                        .foregroundStyle(TVTheme.tertiaryText)
                }

                // 4. 界面交互动效与音效
                group("界面动效与音效") {
                    optionRow(
                        title: "焦点与按键音效",
                        options: ["开启 (推荐)", "关闭"],
                        selectedIndex: env.settings.enableUISoundEffects ? 0 : 1
                    ) { index in
                        let enabled = (index == 0)
                        UISoundPlayer.shared.isEnabled = enabled
                        Task { await env.updateSettings { $0.enableUISoundEffects = enabled } }
                    }
                    Text("遥控器移动焦点、点击选项与返回时播放轻柔苹果风提示音（与视频播放混音，不打断正片声音）。")
                        .font(.system(size: 16))
                        .foregroundStyle(TVTheme.tertiaryText)
                }

                // 5. 局域网自动记住 & 缓存
                group("局域网连接与缓存") {
                    Text("已自动记住 \(env.sources.count) 个局域网网络源（含 SMB / WebDAV / Bonjour 发现）。应用启动后会在后台自动保持连接并记住上次浏览的文件夹，无需每次重连。")
                        .font(.system(size: 17))
                        .foregroundStyle(TVTheme.secondaryText)

                    optionRow(
                        title: "环形预读上限",
                        options: ["64 MB", "96 MB", "128 MB", "160 MB", "192 MB"],
                        selectedIndex: [64, 96, 128, 160, 192].firstIndex(of: env.settings.readAheadCacheLimitMB) ?? 1
                    ) { index in
                        let values = [64, 96, 128, 160, 192]
                        Task { await env.updateSettings { $0.readAheadCacheLimitMB = values[index] } }
                    }
                    Text("Apple TV 内存上限硬约束 192 MB，快进时自动启用 384 KB 关键帧微缓存直通，确保局域网画面丝滑出帧。")
                        .font(.system(size: 16))
                        .foregroundStyle(TVTheme.tertiaryText)
                }

                // 5. 字幕默认样式
                group("字幕默认样式") {
                    let style = env.settings.subtitleStyle
                    HStack(spacing: 24) {
                        Text("字号 \(Int(style.fontSize)) pt")
                        Text("位置 \(Int(style.bottomOffsetRatio * 100))%")
                        Text("不透明度 \(Int(style.textOpacity * 100))%")
                        Text("延迟 \(String(format: "%+.1f", style.delaySeconds))s")
                        Circle().fill(Color(hex: style.textColorHex)).frame(width: 22, height: 22)
                    }
                    .font(.system(size: 18))
                    .foregroundStyle(TVTheme.secondaryText)
                    Text("在播放页按「字幕样式」边看边调，改动会写回这里作为所有影片的默认值。")
                        .font(.system(size: 16))
                        .foregroundStyle(TVTheme.tertiaryText)
                }

                // 6. 存储与诊断
                group("存储与诊断") {
                    Text("配置目录：\(AppEnvironment.storageDirectory().path)")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(TVTheme.tertiaryText)
                    Text("本地 HTTP 流代理端口：\(env.proxy.port == 0 ? "未启动" : String(env.proxy.port))")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(TVTheme.tertiaryText)
                    if let error = env.proxyError {
                        Text(error).foregroundStyle(.orange).font(.system(size: 16))
                    }
                }
            }
            .padding(.horizontal, TVMetrics.horizontalSafeMargin)
            .padding(.vertical, TVMetrics.verticalSafeMargin)
        }
    }

    private var scrubBarPreview: some View {
        let barColor = Color(hex: env.settings.scrubBarColorHex)
        let barOpacity = env.settings.scrubBarOpacity
        let barHeight = CGFloat(env.settings.scrubBarHeight)
        let timeOpacity = env.settings.scrubTimeTextOpacity

        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.12, green: 0.15, blue: 0.22), Color(red: 0.06, green: 0.08, blue: 0.11)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 86)

            VStack(spacing: 6) {
                if env.settings.showScrubTimeText {
                    HStack {
                        Text(">>> 45x  +02:30")
                        Spacer()
                        Text("00:42:18 / 02:15:00")
                    }
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(timeOpacity))
                    .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
                }

                GeometryReader { proxy in
                    let fillWidth = proxy.size.width * 0.38
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22 * barOpacity))
                        Capsule()
                            .fill(barColor.opacity(barOpacity))
                            .frame(width: fillWidth)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(barColor.opacity(min(1.0, barOpacity + 0.28)))
                            .frame(width: 3, height: barHeight + 4)
                            .offset(x: max(0, fillWidth - 1.5))
                    }
                }
                .frame(height: barHeight)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
    }

    private func closestIndex(_ value: Double, in candidates: [Double]) -> Int {
        var bestIdx = 0
        var bestDiff = Double.greatestFiniteMagnitude
        for (i, c) in candidates.enumerated() {
            let d = abs(c - value)
            if d < bestDiff {
                bestDiff = d
                bestIdx = i
            }
        }
        return bestIdx
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tvGlassSurface(cornerRadius: 20)
        }
    }

    private func optionRow(
        title: String,
        options: [String],
        selectedIndex: Int,
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 220, alignment: .leading)
            ForEach(Array(options.enumerated()), id: \.offset) { index, label in
                Button {
                    onSelect(index)
                } label: {
                    Text(label)
                        .font(.system(size: 17, weight: index == selectedIndex ? .bold : .regular))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            index == selectedIndex ? TVTheme.accent.opacity(0.45) : Color.white.opacity(0.08),
                            in: Capsule()
                        )
                }
                .buttonStyle(TVOptionButtonStyle())
            }
            Spacer()
        }
    }
}
