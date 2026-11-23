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
}
