import SwiftUI
import SubtitleKit

/// Renders side-loaded SRT/VTT (and ASS when style override is on) with live
/// style binding: position, size, colour, opacity, weight, outline, background,
/// and timeline delay — all adjustable while the video keeps playing.
public struct SubtitleOverlayView: View {
    public let track: ParsedSubtitleTrack
    public let style: SubtitleStyleConfig
    public let currentTime: TimeInterval

    public init(track: ParsedSubtitleTrack, style: SubtitleStyleConfig, currentTime: TimeInterval) {
        self.track = track
        self.style = style
        self.currentTime = currentTime
    }

    private var activeText: String {
        let cues = track.activeCues(at: currentTime, delaySeconds: style.delaySeconds)
        guard !cues.isEmpty else { return "" }
        return cues.map(\.text).joined(separator: "\n")
    }

    public var body: some View {
        GeometryReader { proxy in
            let text = activeText
            if !text.isEmpty {
                VStack {
                    Spacer()
                    Text(text)
                        .font(.system(size: style.fontSize, weight: style.swiftWeight))
                        .foregroundStyle(Color(hex: style.textColorHex).opacity(style.textOpacity))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            Color.black.opacity(style.backgroundOpacity),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    Color(hex: style.outlineColorHex).opacity(style.outlineWidth > 0 ? 1 : 0),
                                    lineWidth: style.outlineWidth
                                )
                        )
                        .shadow(color: .black.opacity(0.9), radius: max(1, style.outlineWidth), x: 0, y: 1)
                        .padding(.bottom, proxy.size.height * style.bottomOffsetRatio)
                        .frame(maxWidth: .infinity)
                        .animation(.easeOut(duration: 0.08), value: text)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

public extension SubtitleFontWeight {
    var swiftWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

public extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        switch cleaned.count {
        case 8:
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        case 6:
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1
        default:
            r = 1; g = 1; b = 1; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
