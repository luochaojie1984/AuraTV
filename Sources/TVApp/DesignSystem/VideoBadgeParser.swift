import SwiftUI

/// A coloured capsule badge derived from a filename (4K / DV / HDR10 / HEVC / AV1 / Atmos …).
public struct VideoBadge: Identifiable, Hashable, Sendable {
    public let text: String
    public let tint: String

    public var id: String { text }

    public init(text: String, tint: String) {
        self.text = text
        self.tint = tint
    }
}

public enum VideoBadgeParser {
    private struct Rule {
        let badge: String
        let tint: String
        let patterns: [String]
    }

    private static let rules: [Rule] = [
        Rule(badge: "4K", tint: "#4AA3FF", patterns: ["2160p", "4k", "uhd"]),
        Rule(badge: "1080p", tint: "#6C7A89", patterns: ["1080p", "fhd"]),
        Rule(badge: "720p", tint: "#6C7A89", patterns: ["720p"]),
        Rule(badge: "DV", tint: "#B07CFF", patterns: ["dolbyvision", "dovi", " dv ", "dv.", "dvhdr"]),
        Rule(badge: "HDR10", tint: "#F5A623", patterns: ["hdr10", "hdr"]),
        Rule(badge: "HLG", tint: "#F5A623", patterns: ["hlg"]),
        Rule(badge: "HEVC", tint: "#39C6A0", patterns: ["hevc", "x265", "h265"]),
        Rule(badge: "AV1", tint: "#39C6A0", patterns: ["av1"]),
        Rule(badge: "Atmos", tint: "#FF6B8A", patterns: ["atmos"]),
        Rule(badge: "TrueHD", tint: "#FF8A5B", patterns: ["truehd"]),
        Rule(badge: "DTS", tint: "#FF8A5B", patterns: ["dts"]),
        Rule(badge: "10bit", tint: "#8FA3B0", patterns: ["10bit", "10-bit"])
    ]

    public static func badges(for fileName: String) -> [VideoBadge] {
        let haystack = " " + fileName
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased() + " "
        var seen = Set<String>()
        var result: [VideoBadge] = []
        for rule in rules where !seen.contains(rule.badge) {
            if rule.patterns.contains(where: { haystack.contains($0) }) {
                seen.insert(rule.badge)
                result.append(VideoBadge(text: rule.badge, tint: rule.tint))
            }
        }
        return result
    }
}

public struct BadgeRow: View {
    public let badges: [VideoBadge]

    public init(badges: [VideoBadge]) {
        self.badges = badges
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(badges) { badge in
                Text(badge.text)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black.opacity(0.86))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        Color(hex: badge.tint).opacity(0.92),
                        in: Capsule()
                    )
            }
        }
    }
}
