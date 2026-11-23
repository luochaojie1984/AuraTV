import Foundation
import SubtitleKit

/// Persists user playback settings (MX seek mode, short seek step, cache cap, subtitle appearance).
public actor AppSettingsStore {
    private let fileURL: URL
    private var cached: AppSettings?

    public init(storageDirectory: URL) {
        self.fileURL = storageDirectory.appendingPathComponent("app_settings.json")
    }

    public func load() throws -> AppSettings {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let defaults = AppSettings()
            cached = defaults
            return defaults
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        cached = decoded
        return decoded
    }

    public func save(_ settings: AppSettings) throws {
        var sanitized = settings
        sanitized.readAheadCacheLimitMB = min(max(sanitized.readAheadCacheLimitMB, 64), 192)
        sanitized.shortSeekSeconds = min(max(sanitized.shortSeekSeconds, 3), 60)
        cached = sanitized

        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sanitized)
        try data.write(to: fileURL, options: .atomic)
    }

    public func updateSubtitleStyle(_ mutate: @Sendable (inout SubtitleStyleConfig) -> Void) throws -> SubtitleStyleConfig {
        var current = try load()
        mutate(&current.subtitleStyle)
        try save(current)
        return current.subtitleStyle
    }
}
