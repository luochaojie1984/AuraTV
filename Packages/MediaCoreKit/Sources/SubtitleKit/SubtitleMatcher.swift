import Foundation

public struct SubtitleSourceFile: Sendable, Hashable {
    public let name: String
    public let path: String
    public let isInSubfolder: Bool

    public init(name: String, path: String, isInSubfolder: Bool = false) {
        self.name = name
        self.path = path
        self.isInSubfolder = isInSubfolder
    }
}

public struct MatchedSubtitleCandidate: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let score: Int
    public let detectedLanguageLabel: String
    public let formatExtension: String

    public init(
        name: String,
        path: String,
        score: Int,
        detectedLanguageLabel: String,
        formatExtension: String
    ) {
        self.name = name
        self.path = path
        self.score = score
        self.detectedLanguageLabel = detectedLanguageLabel
        self.formatExtension = formatExtension
    }
}

/// Automatically discovers and ranks external subtitle files from the video's directory
/// and Subs/Subtitles subdirectories by filename match, episode number, and Chinese language preference.
public enum SubtitleMatcher {
    public static let supportedExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sup", "sub"]
    public static let subtitleFolderNames: Set<String> = ["subs", "subtitles", "subtitle", "字幕"]

    public static func match(
        videoFileName: String,
        sameDirectoryFiles: [SubtitleSourceFile],
        subfolderFiles: [SubtitleSourceFile] = []
    ) -> [MatchedSubtitleCandidate] {
        let videoStem = stripExtension(videoFileName).lowercased()
        let videoEpisode = extractEpisodeTag(from: videoStem)

        let allFiles = sameDirectoryFiles + subfolderFiles
        var candidates: [MatchedSubtitleCandidate] = []

        for file in allFiles {
            let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            let rawSubStem = stripExtension(file.name).lowercased()
            let cleanedSubStem = stripLanguageSuffixes(from: rawSubStem)
            var score = 0

            // 1. Filename / Episode match score
            if cleanedSubStem == videoStem || rawSubStem == videoStem {
                score += 100
            } else if rawSubStem.hasPrefix(videoStem) || videoStem.hasPrefix(cleanedSubStem) && cleanedSubStem.count >= 4 {
                score += 80
            } else if let vEp = videoEpisode, let sEp = extractEpisodeTag(from: rawSubStem), vEp == sEp {
                score += 60
            } else if file.isInSubfolder {
                // Inside dedicated Subs/<video>/ folder with generic language name (e.g. Chinese.srt)
                score += 20
            } else {
                // Unrelated file in same directory -> skip auto-match
                continue
            }

            // Slight preference for same directory over subfolder when tied
            if !file.isInSubfolder {
                score += 5
            }

            // 2. Language preference score (Simplified Chinese > Bilingual > Traditional Chinese > English)
            let (langBonus, langLabel) = detectLanguage(in: rawSubStem)
            score += langBonus

            // 3. Format preference (.ass/.ssa slightly preferred over .srt for richer styling)
            if ext == "ass" || ext == "ssa" {
                score += 5
            } else if ext == "srt" || ext == "vtt" {
                score += 2
            }

            candidates.append(
                MatchedSubtitleCandidate(
                    name: file.name,
                    path: file.path,
                    score: score,
                    detectedLanguageLabel: langLabel,
                    formatExtension: ext
                )
            )
        }

        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func stripExtension(_ name: String) -> String {
        URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }

    private static func stripLanguageSuffixes(from stem: String) -> String {
        let tokens = [
            ".zh-hans", ".zh_hans", ".zh-cn", ".zh_cn", ".zh-hant", ".zh_hant", ".zh-tw", ".zh_tw", ".zh-hk",
            ".chs&eng", ".chs.eng", ".eng&chs", ".cht&eng", ".cht.eng", ".sc&jp", ".chs&jpn",
            ".chs", ".cht", ".sc", ".tc", ".zh", ".chi", ".zho", ".cn", ".tw",
            ".eng", ".en", ".jpn", ".ja", ".kor", ".ko",
            ".default", ".forced", ".sdh", ".hi",
            ".简体", ".简中", ".繁体", ".繁中", ".双语", ".特效"
        ]
        var result = stem
        var changed = true
        while changed {
            changed = false
            for token in tokens {
                if result.hasSuffix(token) {
                    result = String(result.dropLast(token.count))
                    changed = true
                }
            }
        }
        return result
    }

    private static func detectLanguage(in lowerStem: String) -> (bonus: Int, label: String) {
        let bilingualMarkers = ["chs&eng", "chs.eng", "eng&chs", "cht&eng", "cht.eng", "双语", "中英", "bilingual"]
        for m in bilingualMarkers where lowerStem.contains(m) {
            return (25, "中英双语")
        }

        let simplifiedMarkers = ["zh-hans", "zh_hans", "zh-cn", "zh_cn", ".chs", "_chs", "-chs", ".sc", "_sc", "简体", "简中", "简日"]
        for m in simplifiedMarkers where lowerStem.contains(m) || lowerStem == m.trimmingCharacters(in: CharacterSet(charactersIn: "._-")) {
            return (30, "简体中文")
        }

        let traditionalMarkers = ["zh-hant", "zh_hant", "zh-tw", "zh_tw", "zh-hk", ".cht", "_cht", "-cht", ".tc", "_tc", "繁体", "繁中", "繁日"]
        for m in traditionalMarkers where lowerStem.contains(m) || lowerStem == m.trimmingCharacters(in: CharacterSet(charactersIn: "._-")) {
            return (20, "繁体中文")
        }

        let genericChineseMarkers = [".zh", "_zh", "-zh", ".chi", ".zho", ".cn", "中文", "chinese"]
        for m in genericChineseMarkers where lowerStem.contains(m) {
            return (22, "中文")
        }

        let englishMarkers = [".eng", "_eng", "-eng", ".en", "_en", "-en", "english"]
        for m in englishMarkers where lowerStem.contains(m) {
            return (10, "English")
        }

        return (0, "外挂字幕")
    }

    private static func extractEpisodeTag(from text: String) -> String? {
        // Match S01E02 or 1x02
        let pattern = #"s(\d{1,2})e(\d{1,3})"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let r1 = Range(match.range(at: 1), in: text),
               let r2 = Range(match.range(at: 2), in: text),
               let season = Int(text[r1]),
               let ep = Int(text[r2]) {
                return String(format: "S%02dE%02d", season, ep)
            }
        }
        return nil
    }
}
