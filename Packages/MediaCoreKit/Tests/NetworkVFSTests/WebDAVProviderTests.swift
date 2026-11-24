import XCTest
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import NetworkVFS

/// Lightweight loopback HTTP/WebDAV mock server for deterministic Linux & Apple CI tests.
private final class MockWebDAVServer: @unchecked Sendable {
    let port: UInt16
    let mediaData: Data
    private let listenFD: Int32
    private var running = true
    private let lock = NSLock()

    private(set) var redirectTriggerHits: Int = 0
    private(set) var token1Hits: Int = 0
    private(set) var token2Hits: Int = 0
    var expireToken1AfterHits: Int = 2
    var return405OnHeadForCDN: Bool = false

    init(mediaData: Data) throws {
        self.mediaData = mediaData
        #if canImport(Glibc)
        let sockType = Int32(SOCK_STREAM.rawValue)
        #else
        let sockType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, sockType, 0)
        precondition(fd >= 0, "socket() failed")
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bindRes == 0, "bind() failed")
        precondition(listen(fd, 16) == 0, "listen() failed")

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &addrLen)
            }
        }
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.listenFD = fd

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        shutdown(listenFD, Int32(SHUT_RDWR))
        close(listenFD)
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning() {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            if clientFD < 0 { break }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let headerEnd = Data("\r\n\r\n".utf8)
        while raw.range(of: headerEnd) == nil {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return }
            raw.append(contentsOf: buf[0..<n])
            if raw.count > 65536 { return }
        }
        guard let reqStr = String(data: raw, encoding: .utf8) else { return }
        let lines = reqStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let idx = line.firstIndex(of: ":") {
                let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
                let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        if path.hasPrefix("/dav") {
            let expectedAuth = "Basic " + Data("admin:secret".utf8).base64EncodedString()
            if headers["authorization"] != expectedAuth {
                sendResponse(fd, status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"DAV\""], body: Data())
                return
            }
        }

        if method == "PROPFIND" && (path == "/dav/dav2/" || path == "/dav/dav2") {
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:href>/dav/dav2/</D:href>
                <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
              </D:response>
              <D:response>
                <D:href>/dav/dav2/ep01.mkv</D:href>
                <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>\(mediaData.count)</D:getcontentlength></D:prop></D:propstat>
              </D:response>
            </D:multistatus>
            """
            sendResponse(fd, status: "207 Multi-Status", headers: ["Content-Type": "application/xml"], body: Data(xml.utf8))
            return
        }

        if method == "PROPFIND" && (path == "/dav/" || path == "/dav") {
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:href>/dav/</D:href>
                <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
              </D:response>
              <D:response>
                <D:href>/dav/Subs/</D:href>
                <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
              </D:response>
              <D:response>
                <D:href>/dav/%E6%B5%81%E6%B5%AA%E5%9C%B0%E7%90%832.2160p.mkv</D:href>
                <D:propstat>
                  <D:prop>
                    <D:resourcetype/>
                    <D:getcontentlength>\(mediaData.count)</D:getcontentlength>
                    <D:getlastmodified>Mon, 23 Nov 2026 12:00:00 GMT</D:getlastmodified>
                  </D:prop>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """
            sendResponse(fd, status: "207 Multi-Status", headers: ["Content-Type": "application/xml"], body: Data(xml.utf8))
            return
        }

        if path.hasPrefix("/dav/") && path.hasSuffix(".mkv") {
            lock.lock()
            redirectTriggerHits += 1
            let targetToken = (token1Hits >= expireToken1AfterHits) ? "/cdn/direct-token-2" : "/cdn/direct-token-1"
            lock.unlock()
            sendResponse(fd, status: "302 Found", headers: ["Location": "http://127.0.0.1:\(port)\(targetToken)"], body: Data())
            return
        }

        if path == "/cdn/direct-token-1" || path == "/cdn/direct-token-2" {
            if path == "/cdn/direct-token-1" {
                lock.lock()
                if method == "GET" {
                    token1Hits += 1
                    let expired = token1Hits > expireToken1AfterHits
                    lock.unlock()
                    if expired {
                        sendResponse(fd, status: "403 Forbidden", headers: [:], body: Data("expired".utf8))
                        return
                    }
                } else {
                    lock.unlock()
                }
            } else if method == "GET" {
                lock.lock()
                token2Hits += 1
                lock.unlock()
            }

            if method == "HEAD" {
                if return405OnHeadForCDN {
                    sendResponse(fd, status: "405 Method Not Allowed", headers: ["Content-Length": "0"], body: Data())
                } else {
                    sendResponse(fd, status: "200 OK", headers: [
                        "Content-Length": "\(mediaData.count)",
                        "Accept-Ranges": "bytes"
                    ], body: Data())
                }
                return
            }

            if let rangeHeader = headers["range"], rangeHeader.hasPrefix("bytes=") {
                let spec = rangeHeader.dropFirst("bytes=".count).split(separator: "-")
                let start = Int(spec[0]) ?? 0
                let end = (spec.count > 1 && !spec[1].isEmpty) ? min(mediaData.count - 1, Int(spec[1]) ?? (mediaData.count - 1)) : (mediaData.count - 1)
                let slice = Data(mediaData[start...end])
                sendResponse(fd, status: "206 Partial Content", headers: [
                    "Content-Range": "bytes \(start)-\(end)/\(mediaData.count)",
                    "Accept-Ranges": "bytes"
                ], body: slice)
                return
            }

            sendResponse(fd, status: "200 OK", headers: ["Accept-Ranges": "bytes"], body: mediaData)
            return
        }

        sendResponse(fd, status: "404 Not Found", headers: [:], body: Data())
    }

    private func sendResponse(_ fd: Int32, status: String, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        var allHeaders = headers
        if allHeaders["Content-Length"] == nil {
            allHeaders["Content-Length"] = "\(body.count)"
        }
        allHeaders["Connection"] = "close"
        for (k, v) in allHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        payload.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < payload.count {
                let n = send(fd, base.advanced(by: sent), payload.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}

final class WebDAVProviderTests: XCTestCase {
    func testPropfindChineseDecodingAndAuth() async throws {
        let payload = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let server = try MockWebDAVServer(mediaData: payload)
        defer { server.stop() }

        let baseURL = URL(string: "http://127.0.0.1:\(server.port)/dav/")!

        let badProvider = WebDAVProvider(baseURL: baseURL, username: "admin", password: "wrong")
        do {
            _ = try await badProvider.listDirectory(at: "/")
            XCTFail("Expected authenticationFailed")
        } catch let err as VFSError {
            XCTAssertEqual(err, .authenticationFailed)
        }

        let provider = WebDAVProvider(baseURL: baseURL, username: "admin", password: "secret")
        let items = try await provider.listDirectory(at: "/")
        XCTAssertEqual(items.count, 2)

        let dir = items.first { $0.isDirectory }
        let video = items.first { !$0.isDirectory }
        XCTAssertEqual(dir?.name, "Subs")
        XCTAssertEqual(video?.name, "流浪地球2.2160p.mkv")
        XCTAssertEqual(video?.size, Int64(payload.count))
        XCTAssertEqual(video?.isVideo, true)
    }

    func test302RedirectCachingAndExpiredDirectLinkAutoRefresh() async throws {
        let payload = Data((0..<16384).map { UInt8(($0 * 17 + 3) & 0xFF) })
        let server = try MockWebDAVServer(mediaData: payload)
        server.expireToken1AfterHits = 2
        defer { server.stop() }

        let baseURL = URL(string: "http://127.0.0.1:\(server.port)/dav/")!
        let provider = WebDAVProvider(baseURL: baseURL, username: "admin", password: "secret")

        let stream = try await provider.openStream(at: "/dav/流浪地球2.2160p.mkv")
        XCTAssertEqual(stream.totalSize, Int64(payload.count))
        XCTAssertEqual(server.redirectTriggerHits, 1, "Initial open resolves 302 once")

        let r1 = try await stream.read(offset: 0, length: 1024)
        let r2 = try await stream.read(offset: 2048, length: 1024)
        XCTAssertEqual(r1, Data(payload[0..<1024]))
        XCTAssertEqual(r2, Data(payload[2048..<3072]))
        XCTAssertEqual(server.redirectTriggerHits, 1, "302 target must be cached across Range reads")
        XCTAssertEqual(server.token1Hits, 2)

        // Read #3 hits expired token1 (403) -> automatically re-resolves to token2 and succeeds
        let r3 = try await stream.read(offset: 8192, length: 2048)
        XCTAssertEqual(r3, Data(payload[8192..<10240]))
        XCTAssertEqual(server.redirectTriggerHits, 2, "Expired 403 must trigger single 302 refresh")
        XCTAssertEqual(server.token2Hits, 1)
    }

    func testPrefixBoundaryForDav2And405HeadRangeFallback() async throws {
        let payload = Data((0..<8192).map { UInt8(($0 * 13 + 5) & 0xFF) })
        let server = try MockWebDAVServer(mediaData: payload)
        server.return405OnHeadForCDN = true
        defer { server.stop() }

        let baseURL = URL(string: "http://127.0.0.1:\(server.port)/dav/")!
        let provider = WebDAVProvider(baseURL: baseURL, username: "admin", password: "secret")

        // Relative "/dav2" under basePath "/dav" MUST become "/dav/dav2/", not "/dav2/"!
        let items = try await provider.listDirectory(at: "/dav2")
        XCTAssertEqual(items.map(\.name), ["ep01.mkv"])

        // 1st open caches 302 target using 405 Range fallback
        let s1 = try await provider.openStream(at: "/dav/dav2/ep01.mkv")
        XCTAssertEqual(s1.totalSize, Int64(payload.count))

        // 2nd open hits cached direct URL and ALSO succeeds when HEAD returns 405!
        let s2 = try await provider.openStream(at: "/dav/dav2/ep01.mkv")
        XCTAssertEqual(s2.totalSize, Int64(payload.count))
    }
}
