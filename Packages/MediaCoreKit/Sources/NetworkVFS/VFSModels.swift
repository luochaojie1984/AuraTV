import Foundation

public struct VFSFileItem: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date?

    public init(
        id: String,
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }

    public var fileExtension: String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }

    public var isVideo: Bool {
        guard !isDirectory else { return false }
        return Self.videoExtensions.contains(fileExtension)
    }

    public var isSubtitle: Bool {
        guard !isDirectory else { return false }
        return Self.subtitleExtensions.contains(fileExtension)
    }

    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "ts", "m2ts", "avi", "flv", "webm", "wmv", "rmvb"
    ]

    public static let subtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "vtt", "sup", "sub", "idx"
    ]
}
