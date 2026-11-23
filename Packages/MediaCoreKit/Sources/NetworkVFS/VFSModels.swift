import Foundation

public enum MediaSourceProtocol: String, Codable, CaseIterable, Sendable {
    case smb
    case webdav
}

public struct MediaSourceConfig: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public var displayName: String
    public var protocolType: MediaSourceProtocol
    public var host: String
    public var port: Int?
    public var useTLS: Bool
    public var basePath: String
    public var username: String
    /// Keychain / credential store key only — NEVER store plaintext password in config JSON.
    public var credentialKey: String
    public var customUserAgent: String?

    public init(
        id: UUID = UUID(),
        displayName: String,
        protocolType: MediaSourceProtocol,
        host: String,
        port: Int? = nil,
        useTLS: Bool = false,
        basePath: String = "/",
        username: String = "",
        credentialKey: String = "",
        customUserAgent: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.protocolType = protocolType
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.basePath = basePath
        self.username = username
        self.credentialKey = credentialKey.isEmpty ? "auratv.cred.\(id.uuidString)" : credentialKey
        self.customUserAgent = customUserAgent
    }
}

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

public enum VFSError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case authenticationFailed
    case notFound(String)
    case invalidRange(offset: Int64, length: Int, totalSize: Int64)
    case fileTooLarge(size: Int64, maxBytes: Int)
    case httpError(statusCode: Int, message: String)
    case xmlParseFailed(String)
    case notConnected
    case cancelled
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid VFS URL: \(url)"
        case .authenticationFailed: return "Authentication failed"
        case .notFound(let path): return "Path not found: \(path)"
        case .invalidRange(let offset, let length, let total):
            return "Invalid read range offset=\(offset) length=\(length) total=\(total)"
        case .fileTooLarge(let size, let max):
            return "File too large (\(size) bytes > max \(max) bytes)"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        case .xmlParseFailed(let msg): return "XML parse error: \(msg)"
        case .notConnected: return "VFS provider is not connected"
        case .cancelled: return "VFS operation cancelled"
        case .ioFailure(let msg): return "VFS I/O error: \(msg)"
        }
    }
}
