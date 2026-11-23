import XCTest
@testable import NetworkVFS

actor MockMemoryStream: VFSRandomAccessStream {
    let buffer: Data
    let delayNanoseconds: UInt64
    nonisolated let totalSize: Int64
    private(set) var readCalls: Int = 0

    init(sizeBytes: Int, delayNanoseconds: UInt64 = 0) {
        var bytes = [UInt8](repeating: 0, count: sizeBytes)
        for i in 0..<sizeBytes {
            bytes[i] = UInt8((i * 31 + 7) & 0xFF)
        }
        self.buffer = Data(bytes)
        self.totalSize = Int64(sizeBytes)
        self.delayNanoseconds = delayNanoseconds
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        readCalls += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        try Task.checkCancellation()
        let start = Int(min(max(0, offset), totalSize))
        let end = Int(min(totalSize, Int64(start + max(0, length))))
        return buffer[start..<end]
    }

    func close() async {}
}

final class ReadAheadStreamCacheTests: XCTestCase {
    func testCrossChunkReadAndCacheHit() async throws {
        let size = 1024 * 1024 // 1 MB
        let upstream = MockMemoryStream(sizeBytes: size)
        let config = StreamCacheConfiguration(
            chunkSize: 64 * 1024,
            maxCacheBytes: 512 * 1024,
            readAheadChunkCount: 2,
            protectedEdgeBytes: 64 * 1024,
            largeSeekThresholdBytes: 256 * 1024
        )
        let cache = ReadAheadStreamCache(upstream: upstream, config: config)

        // Read spanning chunk 0 and chunk 1
        let data = try await cache.read(offset: 60 * 1024, length: 16 * 1024)
        XCTAssertEqual(data.count, 16 * 1024)
        let expected = upstream.buffer[(60 * 1024)..<(76 * 1024)]
        XCTAssertEqual(data, expected)

        // Re-read inside cached range -> hits cache
        let again = try await cache.read(offset: 62 * 1024, length: 8 * 1024)
        XCTAssertEqual(again, upstream.buffer[(62 * 1024)..<(70 * 1024)])
        let metrics = await cache.metrics()
        XCTAssertGreaterThanOrEqual(metrics.cacheHits, 1)

        await cache.close()
    }

    func testHeadAndTailProtectedUnderLRUPressureAndLargeSeekCancelsPrefetch() async throws {
        let chunkSize = 64 * 1024
        let size = chunkSize * 12 // 768 KB (12 chunks: 0..11)
        let upstream = MockMemoryStream(sizeBytes: size, delayNanoseconds: 25_000_000)
        let config = StreamCacheConfiguration(
            chunkSize: chunkSize,
            maxCacheBytes: chunkSize * 4, // Max 4 chunks in cache
            readAheadChunkCount: 2,
            protectedEdgeBytes: chunkSize, // Chunk 0 and Chunk 11 protected
            largeSeekThresholdBytes: Int64(chunkSize * 3)
        )
        let cache = ReadAheadStreamCache(upstream: upstream, config: config)

        // Load head chunk 0 and tail chunk 11
        _ = try await cache.read(offset: 0, length: 1024)
        _ = try await cache.read(offset: Int64(chunkSize * 11), length: 1024)

        // Read several middle chunks to exceed 4-chunk cap
        _ = try await cache.read(offset: Int64(chunkSize * 2), length: 1024)
        _ = try await cache.read(offset: Int64(chunkSize * 3), length: 1024)
        _ = try await cache.read(offset: Int64(chunkSize * 4), length: 1024)
        _ = try await cache.read(offset: Int64(chunkSize * 5), length: 1024)

        // Large seek back to chunk 1 should cancel active prefetches
        _ = try await cache.read(offset: Int64(chunkSize * 1), length: 1024)

        let headCached = await cache.isChunkCached(0)
        let tailCached = await cache.isChunkCached(11)
        let metrics = await cache.metrics()

        XCTAssertTrue(headCached, "Head index chunk 0 should remain pinned")
        XCTAssertTrue(tailCached, "Tail index chunk 11 should remain pinned")
        XCTAssertLessThanOrEqual(metrics.cachedBytes, config.maxCacheBytes)
        XCTAssertGreaterThanOrEqual(metrics.cancelledPrefetches, 1)

        await cache.close()
    }
}
