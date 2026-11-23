import Foundation

/// Random-access read-only stream supporting concurrent cancellation and range reads.
public protocol VFSRandomAccessStream: Sendable {
    var totalSize: Int64 { get }
    func read(offset: Int64, length: Int) async throws -> Data
    func close() async
}

/// Unified virtual file system protocol across SMB2/3, WebDAV, and future protocols.
public protocol VFSProvider: Sendable {
    var scheme: String { get }
    func connect() async throws
    func disconnect() async
    func listDirectory(at path: String) async throws -> [VFSFileItem]
    func openStream(at path: String) async throws -> any VFSRandomAccessStream
    func readFileData(at path: String, maxBytes: Int) async throws -> Data
    func benchmarkThroughput(at path: String, sampleBytes: Int) async throws -> Double
}

public extension VFSProvider {
    /// Default sequential throughput benchmark (returns Mbps).
    func benchmarkThroughput(at path: String, sampleBytes: Int = 20 * 1024 * 1024) async throws -> Double {
        let stream = try await openStream(at: path)
        defer {
            Task { await stream.close() }
        }
        let targetBytes = Int(min(Int64(sampleBytes), stream.totalSize))
        guard targetBytes > 0 else { return 0 }

        let chunkSize = 2 * 1024 * 1024
        var offset: Int64 = 0
        var totalRead: Int64 = 0
        let start = Date()

        while totalRead < Int64(targetBytes) {
            try Task.checkCancellation()
            let remaining = Int(Int64(targetBytes) - totalRead)
            let toRead = min(chunkSize, remaining)
            let data = try await stream.read(offset: offset, length: toRead)
            if data.isEmpty { break }
            totalRead += Int64(data.count)
            offset += Int64(data.count)
        }

        let elapsed = max(Date().timeIntervalSince(start), 0.0001)
        let megabits = (Double(totalRead) * 8.0) / 1_000_000.0
        return megabits / elapsed
    }
}
