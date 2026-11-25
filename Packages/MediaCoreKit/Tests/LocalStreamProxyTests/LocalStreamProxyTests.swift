import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LocalStreamProxy
import NetworkVFS

private final class InMemoryVideoStream: VFSRandomAccessStream {
    let data: Data
    var totalSize: Int64 { Int64(data.count) }

    init(sizeBytes: Int) {
        var bytes = [UInt8](repeating: 0, count: sizeBytes)
        for i in 0..<sizeBytes {
            bytes[i] = UInt8((i * 73 + 19) & 0xFF)
        }
        self.data = Data(bytes)
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        let start = Int(min(max(0, offset), totalSize))
        let end = Int(min(totalSize, Int64(start + max(0, length))))
        return Data(data[start..<end])
    }

    func close() async {}
}

private func fetchSync(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await withCheckedThrowingContinuation { continuation in
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                continuation.resume(throwing: URLError(.badServerResponse))
                return
            }
            continuation.resume(returning: (data ?? Data(), http))
        }
        task.resume()
    }
}

final class LocalStreamProxyTests: XCTestCase {
    func testHeadFullGetAndConcurrentRangeRequests() async throws {
        let proxy = LocalHTTPStreamProxy()
        try proxy.start()
        defer { proxy.stop() }

        let totalBytes = 1_200_000 // ~1.2 MB
        let source = InMemoryVideoStream(sizeBytes: totalBytes)
        let (token, url) = try proxy.register(stream: source, fileName: "Blade.Runner.2049.2160p.mkv")
        defer { proxy.unregister(token: token) }

        // 1. HEAD check
        var headReq = URLRequest(url: url)
        headReq.httpMethod = "HEAD"
        let (_, headResp) = try await fetchSync(headReq)
        XCTAssertEqual(headResp.statusCode, 200)
        XCTAssertEqual(headResp.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(headResp.value(forHTTPHeaderField: "Content-Length"), "\(totalBytes)")

        // 2. Full GET byte-for-byte match
        let (fullData, fullResp) = try await fetchSync(URLRequest(url: url))
        XCTAssertEqual(fullResp.statusCode, 200)
        XCTAssertEqual(fullData, source.data)

        // 3. Concurrent Range requests (start-end, open-ended, suffix)
        async let r1: (Data, HTTPURLResponse) = {
            var req = URLRequest(url: url)
            req.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
            return try await fetchSync(req)
        }()
        async let r2: (Data, HTTPURLResponse) = {
            var req = URLRequest(url: url)
            req.setValue("bytes=500000-565535", forHTTPHeaderField: "Range")
            return try await fetchSync(req)
        }()
        async let r3: (Data, HTTPURLResponse) = {
            var req = URLRequest(url: url)
            req.setValue("bytes=-8192", forHTTPHeaderField: "Range")
            return try await fetchSync(req)
        }()

        let (d1, h1) = try await r1
        let (d2, h2) = try await r2
        let (d3, h3) = try await r3

        XCTAssertEqual(h1.statusCode, 206)
        XCTAssertEqual(d1, Data(source.data[0...4095]))
        XCTAssertEqual(h1.value(forHTTPHeaderField: "Content-Range"), "bytes 0-4095/\(totalBytes)")

        XCTAssertEqual(h2.statusCode, 206)
        XCTAssertEqual(d2, Data(source.data[500000...565535]))

        XCTAssertEqual(h3.statusCode, 206)
        XCTAssertEqual(d3, Data(source.data[(totalBytes - 8192)..<totalBytes]))

        // 4. Out-of-bounds Range -> 416
        var badReq = URLRequest(url: url)
        badReq.setValue("bytes=9999999-10000000", forHTTPHeaderField: "Range")
        let (_, badResp) = try await fetchSync(badReq)
        XCTAssertEqual(badResp.statusCode, 416)
    }

    func testUnregisteredStreamReturns404() async throws {
        let proxy = LocalHTTPStreamProxy()
        try proxy.start()
        defer { proxy.stop() }

        let badURL = URL(string: "http://127.0.0.1:\(proxy.port)/stream/nonexistent/movie.mkv")!
        let (_, resp) = try await fetchSync(URLRequest(url: badURL))
        XCTAssertEqual(resp.statusCode, 404)
    }

    func testEnsureRunningRecoversAfterStopAndForceRestart() async throws {
        let proxy = LocalHTTPStreamProxy()
        try proxy.start()
        defer { proxy.stop() }

        let initialPort = proxy.port
        XCTAssertGreaterThan(initialPort, 0)

        let source1 = InMemoryVideoStream(sizeBytes: 128_000)
        let (tok1, url1) = try proxy.register(stream: source1, fileName: "sample1.mkv")
        let (d1, r1) = try await fetchSync(URLRequest(url: url1))
        XCTAssertEqual(r1.statusCode, 200)
        XCTAssertEqual(d1, source1.data)

        // Alive listener should be kept untouched when forceRestart is false.
        try proxy.ensureRunning(forceRestart: false)
        XCTAssertEqual(proxy.port, initialPort)
        let (_, r1Again) = try await fetchSync(URLRequest(url: url1))
        XCTAssertEqual(r1Again.statusCode, 200)
        proxy.unregister(token: tok1)

        // Force restart should bind a live socket and serve Range requests cleanly.
        try proxy.ensureRunning(forceRestart: true)
        XCTAssertGreaterThan(proxy.port, 0)
        let source2 = InMemoryVideoStream(sizeBytes: 128_000)
        let (tok2, url2) = try proxy.register(stream: source2, fileName: "sample2.mkv")
        var rangeReq = URLRequest(url: url2)
        rangeReq.setValue("bytes=1024-2047", forHTTPHeaderField: "Range")
        let (d2, r2) = try await fetchSync(rangeReq)
        XCTAssertEqual(r2.statusCode, 206)
        XCTAssertEqual(d2, Data(source2.data[1024...2047]))
        proxy.unregister(token: tok2)

        // Recovery from completely stopped state.
        proxy.stop()
        XCTAssertEqual(proxy.port, 0)
        try proxy.ensureRunning()
        XCTAssertGreaterThan(proxy.port, 0)
        let source3 = InMemoryVideoStream(sizeBytes: 64_000)
        let (tok3, url3) = try proxy.register(stream: source3, fileName: "sample3.mp4")
        let (d3, r3) = try await fetchSync(URLRequest(url: url3))
        XCTAssertEqual(r3.statusCode, 200)
        XCTAssertEqual(d3, source3.data)
        proxy.unregister(token: tok3)
    }
}
