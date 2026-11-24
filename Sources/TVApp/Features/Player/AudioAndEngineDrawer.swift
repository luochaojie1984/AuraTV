import SwiftUI

struct AudioAndEngineDrawer: View {
    let audioTracks: [EngineTrackInfo]
    let embeddedSubtitleTracks: [EngineTrackInfo]
    let activeEngineKind: PreferredEngineChoice
    let currentPreference: PreferredEngineChoice
    let playbackRate: Float
    let aspectMode: VideoAspectMode
    let onSelectRate: (Float) -> Void
    let onSelectAspectMode: (VideoAspectMode) -> Void
    let onSelectAudio: (Int32) -> Void
    let onSelectEmbeddedSubtitle: (Int32?) -> Void
    let onSwitchEngine: (PreferredEngineChoice) -> Void
    let onClose: () -> Void

    private let rateChoices: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("播放设置")
                    .font(.system(size: 28, weight: .bold))
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

            Divider().overlay(Color.white.opacity(0.15))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sectionHeader("播放倍速")
                    HStack(spacing: 10) {
                        ForEach(rateChoices, id: \.self) { rate in
                            let selected = abs(playbackRate - rate) < 0.01
                            Button {
                                onSelectRate(rate)
                            } label: {
                                Text(formatRate(rate))
                                    .font(.system(size: 17, weight: selected ? .bold : .medium, design: .monospaced))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(
                                        selected ? TVTheme.accent.opacity(0.35) : Color.white.opacity(0.08),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(TVOptionButtonStyle())
                        }
                    }

                    sectionHeader("画面比例")
                    HStack(spacing: 10) {
                        ForEach(VideoAspectMode.allCases, id: \.self) { mode in
                            let selected = (mode == aspectMode)
                            Button {
                                onSelectAspectMode(mode)
                            } label: {
                                Text(mode.rawValue)
                                    .font(.system(size: 17, weight: selected ? .bold : .medium))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .background(
                                        selected ? TVTheme.accent.opacity(0.35) : Color.white.opacity(0.08),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(TVOptionButtonStyle())
                        }
                    }

                    sectionHeader("音轨 (\(audioTracks.count))")
                    if audioTracks.isEmpty {
                        Text("暂无可切换音轨")
                            .font(.system(size: 16))
                            .foregroundStyle(TVTheme.tertiaryText)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(audioTracks) { track in
                                Button {
                                    onSelectAudio(track.id)
                                } label: {
                                    drawerRow(selected: track.isEnabled) {
                                        Text(track.name.isEmpty ? "音轨 #\(track.id)" : track.name)
                                            .lineLimit(1)
                                        if let lang = track.languageCode {
                                            Text(lang.uppercased())
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(TVTheme.secondaryText)
                                        }
                                        Spacer()
                                        if track.isEnabled {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(TVTheme.accent)
                                        }
                                    }
                                }
                                .buttonStyle(TVOptionButtonStyle(cornerRadius: 14))
                            }
                        }
                    }

                    sectionHeader("内封字幕 (\(embeddedSubtitleTracks.count))")
                    if embeddedSubtitleTracks.isEmpty {
                        Text("未检测到内封字幕轨")
                            .font(.system(size: 16))
                            .foregroundStyle(TVTheme.tertiaryText)
                    } else {
                        let anyEmbeddedEnabled = embeddedSubtitleTracks.contains(where: \.isEnabled)
                        VStack(spacing: 10) {
                            Button {
                                onSelectEmbeddedSubtitle(nil)
                            } label: {
                                drawerRow(selected: !anyEmbeddedEnabled) {
                                    Text("关闭内封字幕（恢复外挂字幕）")
                                    Spacer()
                                    if !anyEmbeddedEnabled {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(TVTheme.accent)
                                    }
                                }
                            }
                            .buttonStyle(TVOptionButtonStyle(cornerRadius: 14))

                            ForEach(embeddedSubtitleTracks) { sub in
                                Button {
                                    onSelectEmbeddedSubtitle(sub.id)
                                } label: {
                                    drawerRow(selected: sub.isEnabled) {
                                        Text(sub.name.isEmpty ? "内封字幕 #\(sub.id)" : sub.name)
                                            .lineLimit(1)
                                        if sub.isImageSubtitle {
                                            Text("PGS/图形")
                                                .font(.system(size: 13))
                                                .foregroundStyle(TVTheme.accent)
                                        }
                                        Spacer()
                                        if sub.isEnabled {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(TVTheme.accent)
                                        }
                                    }
                                }
                                .buttonStyle(TVOptionButtonStyle(cornerRadius: 14))
                            }
                        }
                    }

                    sectionHeader("解码核心 · \(activeEngineKind.rawValue)")
                    VStack(spacing: 10) {
                        ForEach(PreferredEngineChoice.allCases, id: \.self) { choice in
                            let selected = (choice == currentPreference)
                            Button {
                                onSwitchEngine(choice)
                            } label: {
                                drawerRow(selected: selected) {
                                    Text(choice.rawValue)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(TVTheme.accent)
                                    }
                                }
                            }
                            .buttonStyle(TVOptionButtonStyle(cornerRadius: 14))
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
        .padding(26)
        .frame(width: 560)
        .frame(maxHeight: .infinity)
        .tvGlassSurface(cornerRadius: 26)
    }

    private func formatRate(_ rate: Float) -> String {
        rate == floor(rate) ? String(format: "%.1fx", rate) : String(format: "%.2gx", rate)
    }

    private func drawerRow<Content: View>(selected: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .font(.system(size: 18, weight: selected ? .semibold : .regular))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            selected ? TVTheme.accent.opacity(0.24) : Color.white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(TVTheme.secondaryText)
    }
}
