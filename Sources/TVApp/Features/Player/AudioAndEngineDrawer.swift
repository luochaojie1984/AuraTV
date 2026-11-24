import SwiftUI

struct AudioAndEngineDrawer: View {
    let audioTracks: [EngineTrackInfo]
    let embeddedSubtitleTracks: [EngineTrackInfo]
    let activeEngineKind: PreferredEngineChoice
    let currentPreference: PreferredEngineChoice
    let onSelectAudio: (Int32) -> Void
    let onSelectEmbeddedSubtitle: (Int32?) -> Void
    let onSwitchEngine: (PreferredEngineChoice) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("音轨与解码引擎")
                    .font(.system(size: 28, weight: .bold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
            }

            Divider().overlay(Color.white.opacity(0.15))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sectionHeader("当前解码核心：\(activeEngineKind.rawValue)")
                    VStack(spacing: 10) {
                        ForEach(PreferredEngineChoice.allCases, id: \.self) { choice in
                            Button {
                                onSwitchEngine(choice)
                            } label: {
                                HStack {
                                    Text(choice.rawValue)
                                    Spacer()
                                    if choice == currentPreference {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(TVTheme.accent)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    sectionHeader("音轨切换 (\(audioTracks.count))")
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
                                    HStack {
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
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    sectionHeader("内封字幕 / PGS 图形字幕 (\(embeddedSubtitleTracks.count))")
                    if embeddedSubtitleTracks.isEmpty {
                        Text("未检测到内封字幕轨")
                            .font(.system(size: 16))
                            .foregroundStyle(TVTheme.tertiaryText)
                    } else {
                        VStack(spacing: 10) {
                            Button {
                                onSelectEmbeddedSubtitle(nil)
                            } label: {
                                HStack {
                                    Text("关闭内封字幕")
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            ForEach(embeddedSubtitleTracks) { sub in
                                Button {
                                    onSelectEmbeddedSubtitle(sub.id)
                                } label: {
                                    HStack {
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
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
        .padding(26)
        .frame(width: 560)
        .frame(maxHeight: .infinity)
        .tvGlassSurface(cornerRadius: 26)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(TVTheme.secondaryText)
    }
}
