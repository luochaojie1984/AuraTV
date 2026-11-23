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

    /// Focus visual for cards: subtle scale + brighter surface, 10-foot friendly.
    func tvCardFocus(_ isFocused: Bool, cornerRadius: CGFloat = TVMetrics.cardCornerRadius) -> some View {
        self
            .background(
                isFocused ? TVTheme.cardFocused : TVTheme.card,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 0.55 : 0.08), lineWidth: isFocused ? 2 : 1)
            )
            .scaleEffect(isFocused ? TVMetrics.focusScale : 1.0)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}
