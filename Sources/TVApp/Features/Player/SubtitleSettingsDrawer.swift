import SwiftUI
import SubtitleKit

/// 右侧半透明字幕与样式抽屉：支持切换同目录外挂字幕，并实时调整外观与时间轴。
struct SubtitleSettingsDrawer: View {
    let style: SubtitleStyleConfig
    let externalSubtitles: [MatchedSubtitleCandidate]
    let selectedExternalPath: String?
    let onSelectExternalSubtitle: (MatchedSubtitleCandidate?) -> Void
    let onStyleChange: (@escaping @Sendable (inout SubtitleStyleConfig) -> Void) -> Void
    let onClose: () -> Void

    private var activeSubtitleLabel: String {
        if let selectedExternalPath,
           let match = externalSubtitles.first(where: { $0.path == selectedExternalPath }) {
            return "\(match.detectedLanguageLabel) · \(match.formatExtension.uppercased())"
        }
        return externalSubtitles.isEmpty ? "未检测到外挂字幕" : "已关闭外挂字幕"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("字幕与样式")
                        .font(.system(size: 28, weight: .bold))
                    Text(activeSubtitleLabel)
                        .font(.system(size: 16))
                        .foregroundStyle(TVTheme.secondaryText)
                }
                Spacer()
                Button {
                    UISoundPlayer.shared.playBack()
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .padding(4)
                }
                .buttonStyle(TVOptionButtonStyle())
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)

            Divider().opacity(0.3)

            ScrollView {
                VStack(spacing: 12) {
                    if !externalSubtitles.isEmpty {
                        externalTrackSection
                    }

                    stepperRow(
                        title: "字号",
                        value: "\(Int(style.fontSize)) pt",
                        onMinus: { onStyleChange { $0.fontSize = max(32, $0.fontSize - 2) } },
                        onPlus: { onStyleChange { $0.fontSize = min(96, $0.fontSize + 2) } }
                    )
                    stepperRow(
                        title: "垂直位置",
                        value: "\(Int(style.bottomOffsetRatio * 100))%",
                        onMinus: { onStyleChange { $0.bottomOffsetRatio = max(0, $0.bottomOffsetRatio - 0.01) } },
                        onPlus: { onStyleChange { $0.bottomOffsetRatio = min(0.35, $0.bottomOffsetRatio + 0.01) } }
                    )
                    stepperRow(
                        title: "不透明度",
                        value: "\(Int(style.textOpacity * 100))%",
                        onMinus: { onStyleChange { $0.textOpacity = max(0.4, $0.textOpacity - 0.05) } },
                        onPlus: { onStyleChange { $0.textOpacity = min(1.0, $0.textOpacity + 0.05) } }
                    )
                    stepperRow(
                        title: "描边",
                        value: String(format: "%.1f", style.outlineWidth),
                        onMinus: { onStyleChange { $0.outlineWidth = max(0, $0.outlineWidth - 0.5) } },
                        onPlus: { onStyleChange { $0.outlineWidth = min(6, $0.outlineWidth + 0.5) } }
                    )
                    stepperRow(
                        title: "背景暗框",
                        value: "\(Int(style.backgroundOpacity * 100))%",
                        onMinus: { onStyleChange { $0.backgroundOpacity = max(0, $0.backgroundOpacity - 0.05) } },
                        onPlus: { onStyleChange { $0.backgroundOpacity = min(0.8, $0.backgroundOpacity + 0.05) } }
                    )
                    stepperRow(
                        title: "时间轴延迟",
                        value: String(format: "%+.1f s", style.delaySeconds),
                        onMinus: { onStyleChange { $0.delaySeconds = max(-30, $0.delaySeconds - 0.1) } },
                        onPlus: { onStyleChange { $0.delaySeconds = min(30, $0.delaySeconds + 0.1) } }
                    )

                    colorRow
                    weightRow
                    toggleRow
                }
                .padding(26)
            }
        }
        .frame(width: 560)
        .frame(maxHeight: .infinity)
        .tvGlassSurface(cornerRadius: 26)
    }

    private var externalTrackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("外挂字幕轨 (\(externalSubtitles.count))")
                .font(.system(size: 18, weight: .semibold))

            Button {
                onSelectExternalSubtitle(nil)
            } label: {
                let offSelected = (selectedExternalPath == nil)
                HStack {
                    Text("关闭外挂字幕")
                    Spacer()
                    if offSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(TVTheme.accent)
                    }
                }
                .font(.system(size: 16, weight: offSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    offSelected ? TVTheme.accent.opacity(0.24) : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(TVOptionButtonStyle(cornerRadius: 12))

            ForEach(externalSubtitles) { candidate in
                let active = (candidate.path == selectedExternalPath)
                Button {
                    onSelectExternalSubtitle(candidate)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name)
                                .font(.system(size: 16, weight: active ? .semibold : .regular))
                                .lineLimit(1)
                            Text("\(candidate.detectedLanguageLabel) · \(candidate.formatExtension.uppercased())")
                                .font(.system(size: 13))
                                .foregroundStyle(TVTheme.secondaryText)
                        }
                        Spacer()
                        if active {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(TVTheme.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        active ? TVTheme.accent.opacity(0.24) : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(TVOptionButtonStyle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文字颜色").font(.system(size: 18, weight: .semibold))
            HStack(spacing: 14) {
                ForEach(SubtitleColorPreset.allCases, id: \.self) { preset in
                    Button {
                        onStyleChange { $0.textColorHex = preset.rawValue }
                    } label: {
                        Circle()
                            .fill(Color(hex: preset.rawValue))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Circle().strokeBorder(
                                    style.textColorHex == preset.rawValue ? TVTheme.accent : .white.opacity(0.25),
                                    lineWidth: style.textColorHex == preset.rawValue ? 3 : 1
                                )
                            )
                    }
                    .buttonStyle(TVOptionButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var weightRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("字重").font(.system(size: 18, weight: .semibold))
            HStack(spacing: 12) {
                ForEach(SubtitleFontWeight.allCases, id: \.self) { weight in
                    Button {
                        onStyleChange { $0.fontWeight = weight }
                    } label: {
                        Text(weightLabel(weight))
                            .font(.system(size: 17, weight: weight.swiftWeight))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                style.fontWeight == weight ? TVTheme.accent.opacity(0.35) : Color.white.opacity(0.08),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(TVOptionButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var toggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("统一文字样式").font(.system(size: 18, weight: .semibold))
                Text("统一外挂字幕的字号、配色与位置").font(.system(size: 15)).foregroundStyle(TVTheme.secondaryText)
            }
            Spacer()
            Button {
                onStyleChange { $0.overrideASSStyles.toggle() }
            } label: {
                Text(style.overrideASSStyles ? "ON" : "OFF")
                    .font(.system(size: 18, weight: .bold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        style.overrideASSStyles ? Color.green.opacity(0.55) : Color.white.opacity(0.12),
                        in: Capsule()
                    )
            }
            .buttonStyle(TVOptionButtonStyle())
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func weightLabel(_ weight: SubtitleFontWeight) -> String {
        switch weight {
        case .regular: return "常规"
        case .medium: return "中等"
        case .semibold: return "半粗"
        case .bold: return "粗体"
        }
    }

    private func stepperRow(
        title: String,
        value: String,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 19, weight: .medium))
            Spacer()
            Button(action: onMinus) { Image(systemName: "minus.circle.fill").font(.system(size: 26)) }
                .buttonStyle(TVOptionButtonStyle())
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .monospaced))
                .frame(width: 96, alignment: .center)
            Button(action: onPlus) { Image(systemName: "plus.circle.fill").font(.system(size: 26)) }
                .buttonStyle(TVOptionButtonStyle())
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
