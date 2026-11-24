import SwiftUI

/// tvOS 26/27 native Liquid Glass with a graceful tvOS 17 material fallback.
public struct AdaptiveGlassSurface: ViewModifier {
    let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )
        }
    }
}

public extension View {
    func tvGlassSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(AdaptiveGlassSurface(cornerRadius: cornerRadius))
    }

    /// Apple-grade tvOS focus visual for cards: spring lift, luminous specular rim, ambient elevation shadow.
    func tvCardFocus(_ isFocused: Bool, isPressed: Bool = false, cornerRadius: CGFloat = TVMetrics.cardCornerRadius) -> some View {
        let scale: CGFloat = isPressed ? 0.97 : (isFocused ? TVMetrics.focusScale : 1.0)
        return self
            .background(
                isFocused ? TVTheme.cardFocused : TVTheme.card,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isFocused ? 0.72 : 0.14),
                                .white.opacity(isFocused ? 0.25 : 0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .shadow(
                color: .black.opacity(isFocused ? 0.45 : 0.0),
                radius: isFocused ? 22 : 0,
                x: 0,
                y: isFocused ? 12 : 0
            )
            .scaleEffect(scale)
            .animation(.spring(response: 0.26, dampingFraction: 0.76), value: isFocused)
            .animation(.spring(response: 0.16, dampingFraction: 0.75), value: isPressed)
    }
}

/// Unified Apple-style card button (Home / Sources / Discovery) with spring elevation & UI sound.
public struct TVCardButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = TVMetrics.cardCornerRadius) {
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        TVCardButtonContainer(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct TVCardButtonContainer: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .tvCardFocus(isFocused, isPressed: configuration.isPressed, cornerRadius: cornerRadius)
                .onChange(of: isFocused) { _, focused in
                    if focused { UISoundPlayer.shared.playFocus() }
                }
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { UISoundPlayer.shared.playSelect() }
                }
        }
    }
}

/// Unified Apple-style list row button (FileBrowser) with crisp glass highlight, spring lift & UI sound.
public struct TVListRowButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        TVListRowContainer(configuration: configuration)
    }

    private struct TVListRowContainer: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let scale: CGFloat = configuration.isPressed ? 0.985 : (isFocused ? 1.018 : 1.0)
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isFocused ? Color.white.opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(isFocused ? 0.42 : 0.0), lineWidth: 1.5)
                )
                .shadow(
                    color: .black.opacity(isFocused ? 0.35 : 0),
                    radius: isFocused ? 14 : 0,
                    x: 0,
                    y: isFocused ? 8 : 0
                )
                .scaleEffect(scale)
                .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isFocused)
                .animation(.spring(response: 0.14, dampingFraction: 0.75), value: configuration.isPressed)
                .onChange(of: isFocused) { _, focused in
                    if focused { UISoundPlayer.shared.playFocus() }
                }
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { UISoundPlayer.shared.playSelect() }
                }
        }
    }
}

/// Unified Apple-style pill / option / color-chip button (Settings, Drawers, HUD)
/// with unmistakable focus ring, spring pop, tactile press bounce, and UI sound.
public struct TVOptionButtonStyle: ButtonStyle {
    public var accentColor: Color
    public var cornerRadius: CGFloat

    public init(accentColor: Color = TVTheme.accent, cornerRadius: CGFloat = 999) {
        self.accentColor = accentColor
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        TVOptionButtonContainer(
            configuration: configuration,
            accentColor: accentColor,
            cornerRadius: cornerRadius
        )
    }

    private struct TVOptionButtonContainer: View {
        let configuration: Configuration
        let accentColor: Color
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let scale: CGFloat = configuration.isPressed ? 0.94 : (isFocused ? 1.08 : 1.0)
            configuration.label
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.white.opacity(0.92) : Color.clear,
                            lineWidth: 2.5
                        )
                )
                .shadow(
                    color: isFocused ? accentColor.opacity(0.45) : .clear,
                    radius: isFocused ? 12 : 0,
                    x: 0,
                    y: isFocused ? 4 : 0
                )
                .scaleEffect(scale)
                .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isFocused)
                .animation(.spring(response: 0.14, dampingFraction: 0.72), value: configuration.isPressed)
                .onChange(of: isFocused) { _, focused in
                    if focused { UISoundPlayer.shared.playFocus() }
                }
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { UISoundPlayer.shared.playSelect() }
                }
        }
    }
}
