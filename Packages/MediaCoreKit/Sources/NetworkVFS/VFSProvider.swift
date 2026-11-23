import Foundation

public protocol VFSRandomAccessStream: Sendable {
    var totalSize: Int64 { get }
    func read(offset: Int64, length: Int) async throws -> Data
    func close() async
}

public protocol VFSProvider: Sendable {
    var scheme: String { get }
    func connect() async throws
    func disconnect() async
    func listDirectory(at path: String) async throws -> [VFSFileItem]
    func openStream(at path: String) async throws -> any VFSRandomAccessStream
    func readFileData(at path: String, maxBytes: Int) async throws -> Data
    func benchmarkThroughput(at path: String, sampleBytes: Int) async throws -> Double
}
