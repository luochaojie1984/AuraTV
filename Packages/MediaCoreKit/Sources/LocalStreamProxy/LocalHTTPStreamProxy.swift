import Foundation
import NetworkVFS
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct LocalStreamProxyInfo: Sendable, Equatable {
    public let version: String
    public let port: UInt16

    public init(version: String = "1.0.0", port: UInt16 = 0) {
        self.version = version
        self.port = port
    }
}

public enum LocalStreamProxyError: Error, LocalizedError, Sendable {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case notStarted

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let code): return "socket() failed with errno \(code)"
        case .bindFailed(let code): return "bind(127.0.0.1:0) failed with errno \(code)"
        case .listenFailed(let code): return "listen() failed with errno \(code)"
        case .notStarted: return "LocalHTTPStreamProxy is not started"
        }
    }
}

private struct RegisteredStreamEntry: Sendable {
    let stream: any VFSRandomAccessStream
    let contentType: String
}

/// Loopback-only (127.0.0.1) HTTP/1.1 Range server that bridges any VFSProvider
/// (SMB2/3, WebDAV, etc.) + ReadAheadStreamCache to native players (KSPlayer / MPVKit / AVPlayer).
public final class LocalHTTPStreamProxy: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var isRunning: Bool = false
    private var streams: [String: RegisteredStreamEntry] = [:]

    public init() {}

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        if isRunning {
            lock.unlock()
            return
        }

        #if canImport(Glibc)
        let sockType = Int32(SOCK_STREAM.rawValue)
        #else
        let sockType = SOCK_STREAM
        #endif

        let fd = socket(AF_INET, sockType, 0)
        if fd < 0 {
            let err = errno
            lock.unlock()
            throw LocalStreamProxyError.socketCreationFailed(err)
        }

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
        if bindRes != 0 {
            let err = errno
            close(fd)
            lock.unlock()
            throw LocalStreamProxyError.bindFailed(err)
        }

        if listen(fd, 32) != 0 {
            let err = errno
            close(fd)
            lock.unlock()
            throw LocalStreamProxyError.listenFailed(err)
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &addrLen)
            }
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.isRunning = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        let wasRunning = isRunning
        listenFD = -1
        isRunning = false
        let existingStreams = streams
        streams.removeAll()
        port = 0
        lock.unlock()

        if wasRunning && fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
        for (_, entry) in existingStreams {
            Task { await entry.stream.close() }
        }
    }

    /// Registers a VFS stream (wrapping with ReadAheadStreamCache if desired) and returns a loopback playback URL.
    public func register(
        stream: any VFSRandomAccessStream,
        fileName: String,
        contentType: String? = nil,
        wrapWithReadAheadCache: Bool = true,
        cacheConfig: StreamCacheConfiguration = StreamCacheConfiguration()
    ) throws -> (token: String, url: URL) {
        lock.lock()
        let currentPort = self.port
        let running = self.isRunning
        lock.unlock()

        guard running, currentPort > 0 else {
            throw LocalStreamProxyError.notStarted
        }

        let token = UUID().uuidString
        let effectiveStream: any VFSRandomAccessStream
        if wrapWithReadAheadCache, !(stream is ReadAheadStreamCache) {
            effectiveStream = ReadAheadStreamCache(upstream: stream, config: cacheConfig)
        } else {
            effectiveStream = stream
        }

        let mime = contentType ?? Self.inferMimeType(from: fileName)
        lock.lock()
        streams[token] = RegisteredStreamEntry(stream: effectiveStream, contentType: mime)
        lock.unlock()

        let safeName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video.mkv"
        let url = URL(string: "http://127.0.0.1:\(currentPort)/stream/\(token)/\(safeName)")!
        return (token, url)
    }

    public func unregister(token: String) {
        lock.lock()
        let removed = streams.removeValue(forKey: token)
        lock.unlock()
        if let removed {
            Task { await removed.stream.close() }
        }
    }

    private func lookupStream(token: String) -> RegisteredStreamEntry? {
        lock.lock()
        defer { lock.unlock() }
        return streams[token]
    }

    private func checkRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    private func acceptLoop(listenFD: Int32) {
        while checkRunning() {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &addrLen)
                }
            }
            if clientFD < 0 {
                if !checkRunning() { break }
                continue
            }

            #if canImport(Darwin)
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            #endif

            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.handleConnection(fd: clientFD)
            }
        }
    }

    private func handleConnection(fd: Int32) async {
        defer { close(fd) }

        guard let request = readHTTPRequestHeader(fd: fd) else { return }
        guard request.method == "GET" || request.method == "HEAD" else {
            _ = sendAll(fd: fd, data: makeHeaderResponse(status: "405 Method Not Allowed", headers: [:]))
            return
        }

        // Expect path: /stream/<token>/<filename>
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2, segments[0] == "stream",
              let entry = lookupStream(token: String(segments[1])) else {
            _ = sendAll(fd: fd, data: makeHeaderResponse(status: "404 Not Found", headers: ["Content-Length": "0"]))
            return
        }

        let totalSize = entry.stream.totalSize

        if request.method == "HEAD" {
            let hdr = makeHeaderResponse(status: "200 OK", headers: [
                "Content-Type": entry.contentType,
                "Content-Length": "\(totalSize)",
                "Accept-Ranges": "bytes"
            ])
            _ = sendAll(fd: fd, data: hdr)
            return
        }

        // Parse optional Range header
        let byteRange: ClosedRange<Int64>
        let isPartial: Bool
        if let rangeHeader = request.headers["range"] {
            guard let parsed = Self.parseByteRange(rangeHeader, totalSize: totalSize) else {
                let hdr = makeHeaderResponse(status: "416 Range Not Satisfiable", headers: [
                    "Content-Range": "bytes */\(totalSize)",
                    "Content-Length": "0"
                ])
                _ = sendAll(fd: fd, data: hdr)
                return
            }
            byteRange = parsed
            isPartial = true
        } else {
            guard totalSize > 0 else {
                let hdr = makeHeaderResponse(status: "200 OK", headers: [
                    "Content-Type": entry.contentType,
                    "Content-Length": "0",
                    "Accept-Ranges": "bytes"
                ])
                _ = sendAll(fd: fd, data: hdr)
                return
            }
            byteRange = 0...(totalSize - 1)
            isPartial = false
        }

        let contentLength = byteRange.upperBound - byteRange.lowerBound + 1
        var respHeaders: [String: String] = [
            "Content-Type": entry.contentType,
            "Content-Length": "\(contentLength)",
            "Accept-Ranges": "bytes"
        ]
        if isPartial {
            respHeaders["Content-Range"] = "bytes \(byteRange.lowerBound)-\(byteRange.upperBound)/\(totalSize)"
        }

        let headerData = makeHeaderResponse(
            status: isPartial ? "206 Partial Content" : "200 OK",
            headers: respHeaders
        )
        guard sendAll(fd: fd, data: headerData) else { return }

        // Stream requested byte range in 256 KB slices; abort cleanly if client disconnects
        let sliceSize = 256 * 1024
        var cursor = byteRange.lowerBound
        while cursor <= byteRange.upperBound {
            if Task.isCancelled || !checkRunning() { break }
            let remaining = byteRange.upperBound - cursor + 1
            let toRead = Int(min(Int64(sliceSize), remaining))
            do {
                let chunk = try await entry.stream.read(offset: cursor, length: toRead)
                if chunk.isEmpty { break }
                if !sendAll(fd: fd, data: chunk) {
                    // Client closed socket (e.g. MX live scrub seek aborted old request)
                    break
                }
                cursor += Int64(chunk.count)
            } catch {
                break
            }
        }
    }

    private struct ParsedHTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private func readHTTPRequestHeader(fd: Int32) -> ParsedHTTPRequest? {
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let delimiter = Data("\r\n\r\n".utf8)

        while raw.range(of: delimiter) == nil {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return nil }
            raw.append(contentsOf: buf[0..<n])
            if raw.count > 65536 { return nil }
        }

        guard let headerRange = raw.range(of: delimiter),
              let headerStr = String(data: raw[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        return ParsedHTTPRequest(method: method, path: rawPath, headers: headers)
    }

    private func makeHeaderResponse(status: String, headers: [String: String]) -> Data {
        var out = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers {
            out += "\(k): \(v)\r\n"
        }
        out += "Connection: close\r\n\r\n"
        return Data(out.utf8)
    }

    private func sendAll(fd: Int32, data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return true }
            var totalSent = 0
            while totalSent < data.count {
                #if canImport(Glibc)
                let flags = Int32(MSG_NOSIGNAL)
                #else
                let flags: Int32 = 0
                #endif
                let n = send(fd, base.advanced(by: totalSent), data.count - totalSent, flags)
                if n <= 0 { return false }
                totalSent += n
            }
            return true
        }
    }

    internal static func parseByteRange(_ header: String, totalSize: Int64) -> ClosedRange<Int64>? {
        guard totalSize > 0 else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst("bytes=".count))
        // Take first range if multiple comma-separated ranges are specified
        let firstSpec = spec.split(separator: ",", maxSplits: 1).first.map(String.init) ?? spec
        guard let dashIdx = firstSpec.firstIndex(of: "-") else { return nil }

        let startStr = String(firstSpec[..<dashIdx]).trimmingCharacters(in: .whitespaces)
        let endStr = String(firstSpec[firstSpec.index(after: dashIdx)...]).trimmingCharacters(in: .whitespaces)

        if startStr.isEmpty {
            // Suffix range: bytes=-N
            guard let suffix = Int64(endStr), suffix > 0 else { return nil }
            let start = max(0, totalSize - suffix)
            return start...(totalSize - 1)
        } else {
            guard let start = Int64(startStr), start >= 0, start < totalSize else { return nil }
            if endStr.isEmpty {
                return start...(totalSize - 1)
            } else {
                guard let end = Int64(endStr), end >= start else { return nil }
                return start...min(end, totalSize - 1)
            }
        }
    }

    private static func inferMimeType(from fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "mkv": return "video/x-matroska"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "ts", "m2ts": return "video/mp2t"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        default: return "application/octet-stream"
        }
    }
}
