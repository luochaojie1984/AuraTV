import SwiftUI

/// Dark cinema palette + 10-foot UI metrics shared across every screen.
public enum TVTheme {
    public static let backgroundTop = Color(red: 0.043, green: 0.055, blue: 0.078)   // #0B0E14
    public static let backgroundBottom = Color(red: 0.078, green: 0.098, blue: 0.137) // #141923
    public static let accent = Color(red: 0.36, green: 0.78, blue: 1.0)
    public static let secondaryText = Color.white.opacity(0.72)
    public static let tertiaryText = Color.white.opacity(0.5)
    public static let card = Color.white.opacity(0.06)
    public static let cardFocused = Color.white.opacity(0.16)

    public static var backdrop: some View {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Deep cinema obsidian backdrop with subtle top aurora glow matching AuraTV's 3D icon.
    public static var cinemaBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.024, green: 0.035, blue: 0.067),
                    Color(red: 0.055, green: 0.082, blue: 0.145)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(red: 0.055, green: 0.647, blue: 0.914).opacity(0.16), .clear],
                center: UnitPoint(x: 0.25, y: 0.06),
                startRadius: 20,
                endRadius: 880
            )
            RadialGradient(
                colors: [Color(red: 0.388, green: 0.400, blue: 0.945).opacity(0.14), .clear],
                center: UnitPoint(x: 0.78, y: 0.18),
                startRadius: 20,
                endRadius: 820
            )
        }
    }
}

public enum TVMetrics {
    public static let horizontalSafeMargin: CGFloat = 44
    public static let verticalSafeMargin: CGFloat = 32
    public static let cardCornerRadius: CGFloat = 22
    public static let focusScale: CGFloat = 1.045
}

/// Horizontally scrolls a long CJK title after a short dwell so nothing is ever
/// truncated in the 10-foot UI. Resets when the text changes or focus is lost.
public struct MarqueeTextView: View {
    public let text: String
    public var font: Font = .system(size: 30, weight: .semibold)
    public var color: Color = .white
    public var dwell: Double = 0.8
    public var speed: CGFloat = 60 // points per second

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var task: Task<Void, Never>?

    public init(
        text: String,
        font: Font = .system(size: 30, weight: .semibold),
        color: Color = .white,
        dwell: Double = 0.8,
        speed: CGFloat = 60
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.dwell = dwell
        self.speed = speed
    }

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }

    public var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .background(
                    GeometryReader { inner in
                        Color.clear.onAppear {
                            textWidth = inner.size.width
                            boxWidth = available
                            restart()
                        }
                        .onChange(of: inner.size.width) { _, newValue in
                            textWidth = newValue
                            restart()
                        }
                    }
                )
                .offset(x: -offset)
                .frame(width: available, alignment: .leading)
                .clipped()
                .onChange(of: text) { _, _ in
                    offset = 0
                    restart()
                }
                .onDisappear { task?.cancel() }
        }
    }

    private func restart() {
        task?.cancel()
        guard overflow > 1 else { return }
        task = Task { @MainActor in
            offset = 0
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                let distance = overflow
                let duration = max(2.0, Double(distance / speed))
                withAnimation(.linear(duration: duration)) { offset = distance }
                try? await Task.sleep(nanoseconds: UInt64((duration + 1.0) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { offset = 0 }
                try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            }
        }
    }
}
