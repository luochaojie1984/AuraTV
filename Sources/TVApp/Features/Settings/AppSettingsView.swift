import SwiftUI
import AppPreferences
import SubtitleKit

struct AppSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("设置")
                    .font(.system(size: 44, weight: .heavy))

                group("快进") {
                    optionRow(
                        title: "短按步长",
                        options: [5.0, 10.0, 15.0, 30.0].map { "\(Int($0))s" },
                        selectedIndex: [5.0, 10.0, 15.0, 30.0].firstIndex(of: env.settings.shortSeekSeconds) ?? 1
                    ) { index in
                        let values: [Double] = [5, 10, 15, 30]
                        Task { await env.updateSettings { $0.shortSeekSeconds = values[index] } }
                    }

                    optionRow(
                        title: "长按行为",
                        options: ["MX 实时跳帧", "连续倍速"],
                        selectedIndex: env.settings.longPressSeekMode == .mxLiveKeyframeScrub ? 0 : 1
                    ) { index in
                        Task {
                            await env.updateSettings {
                                $0.longPressSeekMode = index == 0 ? .mxLiveKeyframeScrub : .continuousFastPlay
                            }
                        }
                    }
                }

                group("缓存") {
                    optionRow(
                        title: "环形预读上限",
                        options: ["64 MB", "96 MB", "128 MB", "160 MB", "192 MB"],
                        selectedIndex: [64, 96, 128, 160, 192].firstIndex(of: env.settings.readAheadCacheLimitMB) ?? 1
                    ) { index in
                        let values = [64, 96, 128, 160, 192]
                        Task { await env.updateSettings { $0.readAheadCacheLimitMB = values[index] } }
                    }
                    Text("Apple TV 内存上限硬约束 192 MB，超出会被系统 Jetsam 杀掉。")
                        .font(.system(size: 16))
                        .foregroundStyle(TVTheme.tertiaryText)
                }

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
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
