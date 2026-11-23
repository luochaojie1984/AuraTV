import Foundation

public struct PlaybackHistoryRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { Self.makeKey(sourceID: sourceID, filePath: filePath) }
    public let sourceID: UUID
    public let filePath: String
    public let fileName: String
    public var lastPositionSeconds: TimeInterval
    public var durationSeconds: TimeInterval
    public var lastPlayedAt: Date
    public var selectedSubtitlePath: String?
    public var selectedAudioTrackID: Int32?

    public init(
        sourceID: UUID,
        filePath: String,
        fileName: String,
        lastPositionSeconds: TimeInterval,
        durationSeconds: TimeInterval,
        lastPlayedAt: Date = Date(),
        selectedSubtitlePath: String? = nil,
        selectedAudioTrackID: Int32? = nil
    ) {
        self.sourceID = sourceID
        self.filePath = filePath
        self.fileName = fileName
        self.lastPositionSeconds = max(0, lastPositionSeconds)
        self.durationSeconds = max(0, durationSeconds)
        self.lastPlayedAt = lastPlayedAt
        self.selectedSubtitlePath = selectedSubtitlePath
        self.selectedAudioTrackID = selectedAudioTrackID
    }

    public var progressRatio: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(lastPositionSeconds / durationSeconds, 0), 1)
    }

    /// Considers an item watched once progress exceeds 95%.
    public var isWatched: Bool {
        progressRatio >= 0.95
    }

    public var remainingSeconds: TimeInterval {
        max(0, durationSeconds - lastPositionSeconds)
    }

    public static func makeKey(sourceID: UUID, filePath: String) -> String {
        "\(sourceID.uuidString)::\(filePath)"
    }
}

/// Persists resume positions, selected audio/subtitle tracks, and Continue Watching lists.
public actor PlaybackHistoryStore {
    private let fileURL: URL
    private var recordsByKey: [String: PlaybackHistoryRecord] = [:]
    private var isLoaded: Bool = false

    public init(storageDirectory: URL) {
        self.fileURL = storageDirectory.appendingPathComponent("playback_history.json")
    }

    public func recordProgress(_ record: PlaybackHistoryRecord) throws {
        try loadIfNeeded()
        recordsByKey[record.id] = record
        try persist()
    }

    public func history(sourceID: UUID, filePath: String) throws -> PlaybackHistoryRecord? {
        try loadIfNeeded()
        return recordsByKey[PlaybackHistoryRecord.makeKey(sourceID: sourceID, filePath: filePath)]
    }

    /// Returns unwatched items with meaningful progress (> 15s), sorted most-recently-played first.
    public func continueWatching(limit: Int = 20) throws -> [PlaybackHistoryRecord] {
        try loadIfNeeded()
        return recordsByKey.values
            .filter { !$0.isWatched && $0.lastPositionSeconds >= 15 }
            .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func allRecords() throws -> [PlaybackHistoryRecord] {
        try loadIfNeeded()
        return recordsByKey.values.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }

    public func remove(sourceID: UUID, filePath: String) throws {
        try loadIfNeeded()
        recordsByKey.removeValue(forKey: PlaybackHistoryRecord.makeKey(sourceID: sourceID, filePath: filePath))
        try persist()
    }

    public func clearAll() throws {
        recordsByKey.removeAll()
        isLoaded = true
        try persist()
    }

    public func replaceAll(with records: [PlaybackHistoryRecord]) throws {
        var dict: [String: PlaybackHistoryRecord] = [:]
        for r in records {
            dict[r.id] = r
        }
        recordsByKey = dict
        isLoaded = true
        try persist()
    }

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        defer { isLoaded = true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            recordsByKey = [:]
            return
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = try decoder.decode([PlaybackHistoryRecord].self, from: data)
        var dict: [String: PlaybackHistoryRecord] = [:]
        for r in list {
            dict[r.id] = r
        }
        recordsByKey = dict
    }

    private func persist() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sorted = recordsByKey.values.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
        let data = try encoder.encode(sorted)
        try data.write(to: fileURL, options: .atomic)
    }
}
