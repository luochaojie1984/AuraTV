import Foundation

public struct SubtitleCue: Sendable, Equatable, Identifiable {
    public let id: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(id: Int, startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct ParsedSubtitleTrack: Sendable, Equatable {
    public let cues: [SubtitleCue]
    public let format: String
    public let rawASSContent: String?

    public init(cues: [SubtitleCue], format: String, rawASSContent: String? = nil) {
        self.cues = cues
        self.format = format
        self.rawASSContent = rawASSContent
    }

    /// Returns all cues visible at `playbackTime`, shifted by `delaySeconds`.
    /// Uses binary search over sorted startTime for O(log N) lookup during 60fps playback.
    public func activeCues(at playbackTime: TimeInterval, delaySeconds: TimeInterval = 0) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        let queryTime = playbackTime - delaySeconds

        // Binary search for the first cue with startTime > queryTime
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].startTime <= queryTime {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // Scan backward across overlapping cues (bounded lookback for performance)
        var active: [SubtitleCue] = []
        var idx = low - 1
        var scanned = 0
        while idx >= 0 && scanned < 64 {
            let cue = cues[idx]
            if cue.startTime <= queryTime && queryTime <= cue.endTime {
                active.append(cue)
            } else if queryTime - cue.startTime > 60 {
                break
            }
            idx -= 1
            scanned += 1
        }
        return active.reversed()
    }
}

/// Parses SRT, WebVTT, and ASS/SSA subtitle text into sorted SubtitleCues.
public enum SubtitleParser {
    public static func parse(data: Data, fileExtension: String) -> (track: ParsedSubtitleTrack, encoding: DetectedTextEncoding) {
        let decoded = SubtitleEncodingDetector.decode(data)
        let track = parse(text: decoded.text, fileExtension: fileExtension)
        return (track, decoded.encoding)
    }

    public static func parse(text: String, fileExtension: String) -> ParsedSubtitleTrack {
        let ext = fileExtension.lowercased()
        if ext == "ass" || ext == "ssa" || text.contains("[Events]") {
            return parseASS(text)
        } else if ext == "vtt" || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") {
            return parseSRTOrVTT(text, format: "vtt")
        } else {
            return parseSRTOrVTT(text, format: "srt")
        }
    }

    private static func parseSRTOrVTT(_ text: String, format: String) -> ParsedSubtitleTrack {
        let blocks = text.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        var nextID = 0

        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard !lines.isEmpty else { continue }

            guard let timeLineIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeLine = lines[timeLineIdx]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1].split(separator: " ").first.map(String.init) ?? parts[1]),
                  end >= start else {
                continue
            }

            let bodyLines = lines[(timeLineIdx + 1)...]
            let rawText = bodyLines.joined(separator: "\n")
            let cleaned = stripHTMLAndASSInlineTags(rawText)
            if !cleaned.isEmpty {
                cues.append(SubtitleCue(id: nextID, startTime: start, endTime: end, text: cleaned))
                nextID += 1
            }
        }

        cues.sort { $0.startTime < $1.startTime }
        return ParsedSubtitleTrack(cues: cues, format: format)
    }

    private static func parseASS(_ text: String) -> ParsedSubtitleTrack {
        let lines = text.components(separatedBy: "\n")
        var inEvents = false
        var startIdx = 1
        var endIdx = 2
        var textIdx = 9
        var cues: [SubtitleCue] = []
        var nextID = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inEvents = trimmed.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }

            if trimmed.lowercased().hasPrefix("format:") {
                let fields = trimmed.dropFirst("format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if let s = fields.firstIndex(of: "start") { startIdx = s }
                if let e = fields.firstIndex(of: "end") { endIdx = e }
                if let t = fields.firstIndex(of: "text") { textIdx = t }
                continue
            }

            if trimmed.lowercased().hasPrefix("dialogue:") {
                let body = String(trimmed.dropFirst("dialogue:".count))
                let columns = splitASSDialogue(body, maxFields: textIdx + 1)
                guard columns.count > textIdx,
                      let start = parseASSTimestamp(columns[startIdx]),
                      let end = parseASSTimestamp(columns[endIdx]),
                      end >= start else {
                    continue
                }
                let rawContent = columns[textIdx]
                let cleaned = cleanASSText(rawContent)
                if !cleaned.isEmpty {
                    cues.append(SubtitleCue(id: nextID, startTime: start, endTime: end, text: cleaned))
                    nextID += 1
                }
            }
        }

        cues.sort { $0.startTime < $1.startTime }
        return ParsedSubtitleTrack(cues: cues, format: "ass", rawASSContent: text)
    }

    private static func splitASSDialogue(_ body: String, maxFields: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in body {
            if ch == "," && result.count < maxFields - 1 {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }

    private static func cleanASSText(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        // Strip {...} override tags (e.g., {\pos(960,980)\fs48\c&H00FFFF&})
        if let regex = try? NSRegularExpression(pattern: #"\{[^}]*\}"#) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripHTMLAndASSInlineTags(_ raw: String) -> String {
        var s = raw
        if let regex = try? NSRegularExpression(pattern: #"<[^>]+>|\{[^}]*\}"#) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map(String.init)
        if parts.count == 3,
           let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
            return h * 3600 + m * 60 + s
        } else if parts.count == 2,
                  let m = Double(parts[0]), let s = Double(parts[1]) {
            return m * 60 + s
        }
        return nil
    }

    private static func parseASSTimestamp(_ raw: String) -> TimeInterval? {
        // ASS format: H:MM:SS.cc (centiseconds)
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + s
    }
}
