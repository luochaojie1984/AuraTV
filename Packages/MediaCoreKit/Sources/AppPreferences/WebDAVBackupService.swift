import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NetworkVFS

public struct AuraTVBackupPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let sources: [MediaSourceConfig]
    public let history: [PlaybackHistoryRecord]
    public let settings: AppSettings

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date = Date(),
        sources: [MediaSourceConfig],
        history: [PlaybackHistoryRecord],
        settings: AppSettings
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.sources = sources
        self.history = history
        self.settings = settings
    }
}

/// Free replacement for CloudKit sync on free Apple IDs:
/// exports/restores sources (without passwords), playback history, and subtitle styles to a WebDAV JSON file.
public enum WebDAVBackupService {
    public static func encodeBackup(_ payload: AuraTVBackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    public static func decodeBackup(_ data: Data) throws -> AuraTVBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AuraTVBackupPayload.self, from: data)
    }

    public static func uploadBackup(
        _ payload: AuraTVBackupPayload,
        to targetURL: URL,
        username: String = "",
        password: String = ""
    ) async throws {
        let body = try encodeBackup(payload)
        var req = URLRequest(url: targetURL)
        req.httpMethod = "PUT"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body

        let (_, statusCode) = try await performBackupHTTP(req)
        guard (200...299).contains(statusCode) else {
            throw VFSError.httpError(statusCode: statusCode, message: "WebDAV backup PUT failed")
        }
    }

    public static func downloadBackup(
        from targetURL: URL,
        username: String = "",
        password: String = ""
    ) async throws -> AuraTVBackupPayload {
        var req = URLRequest(url: targetURL)
        req.httpMethod = "GET"
        if !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, statusCode) = try await performBackupHTTP(req)
        guard (200...299).contains(statusCode) else {
            throw VFSError.httpError(statusCode: statusCode, message: "WebDAV backup GET failed")
        }
        return try decodeBackup(data)
    }

    private static func performBackupHTTP(_ request: URLRequest) async throws -> (Data, Int) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: VFSError.ioFailure(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: VFSError.ioFailure("Invalid HTTP response"))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http.statusCode))
            }
            task.resume()
        }
    }
}
