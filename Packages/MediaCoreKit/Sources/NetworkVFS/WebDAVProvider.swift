import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Stores resolved 301/302/307 direct-link targets for WebDAV gateways (AList / OpenList / CD2).
actor WebDAVRedirectCache {
    struct Entry: Sendable {
        let directURL: URL
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let defaultTTL: TimeInterval

    init(defaultTTL: TimeInterval = 300) {
        self.defaultTTL = defaultTTL
    }

    func get(for key: String) -> URL? {
        guard let entry = entries[key] else { return nil }
        if Date() >= entry.expiresAt {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.directURL
    }

    func set(_ url: URL, for key: String, ttl: TimeInterval? = nil) {
        let expiry = Date().addingTimeInterval(ttl ?? defaultTTL)
        entries[key] = Entry(directURL: url, expiresAt: expiry)
    }

    func invalidate(for key: String) {
        entries.removeValue(forKey: key)
    }

    func clearAll() {
        entries.removeAll()
    }
}

/// Captures 301/302/307 redirect location without auto-following so WebDAVProvider can cache the direct URL.
private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct HTTPResult: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

/// Cross-platform (Linux + tvOS) cancellable URLSession async helper.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?

    func set(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let current = task
        lock.unlock()
        current?.cancel()
    }
}

private func performHTTPRequest(session: URLSession, request: URLRequest) async throws -> HTTPResult {
    try Task.checkCancellation()
    let box = TaskBox()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let dataTask = session.dataTask(with: request) { data, response, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                        continuation.resume(throwing: VFSError.cancelled)
                    } else {
                        continuation.resume(throwing: VFSError.ioFailure(error.localizedDescription))
                    }
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: VFSError.ioFailure("Non-HTTP response"))
                    return
                }
                continuation.resume(returning: HTTPResult(data: data ?? Data(), response: http))
            }
            box.set(dataTask)
            dataTask.resume()
        }
    } onCancel: {
        box.cancel()
    }
}

/// Namespace-agnostic WebDAV PROPFIND (Depth: 1) XML parser.
private final class WebDAVPropfindParser: NSObject, XMLParserDelegate {
    private struct RawItem {
        var href: String = ""
        var contentLength: Int64 = 0
        var isCollection: Bool = false
        var lastModified: Date?
    }

    private var items: [RawItem] = []
    private var currentItem: RawItem?
    private var insideResourceType: Bool = false
    private var textBuffer: String = ""

    private static func parseHTTPDate(_ str: String) -> Date? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let rfc1123 = DateFormatter()
        rfc1123.locale = Locale(identifier: "en_US_POSIX")
        rfc1123.timeZone = TimeZone(secondsFromGMT: 0)
        rfc1123.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = rfc1123.date(from: trimmed) { return d }

        let iso = ISO8601DateFormatter()
        return iso.date(from: trimmed)
    }

    func parse(data: Data, requestedPath: String) throws -> [VFSFileItem] {
        items.removeAll()
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "Unknown XML error"
            throw VFSError.xmlParseFailed(reason)
        }

        let normalizedReq = Self.normalizeDirPath(requestedPath)
        var results: [VFSFileItem] = []

        for raw in items {
            let decodedHref = Self.extractDecodedPath(from: raw.href)
            let normalizedHref = raw.isCollection ? Self.normalizeDirPath(decodedHref) : Self.normalizeFilePath(decodedHref)

            if Self.normalizeDirPath(decodedHref) == normalizedReq {
                continue
            }

            let trimmedForName = normalizedHref.hasSuffix("/")
                ? String(normalizedHref.dropLast())
                : normalizedHref
            let name = URL(fileURLWithPath: trimmedForName).lastPathComponent
            if name.isEmpty || name == "/" { continue }

            results.append(
                VFSFileItem(
                    id: normalizedHref,
                    name: name,
                    path: normalizedHref,
                    isDirectory: raw.isCollection,
                    size: raw.isCollection ? 0 : raw.contentLength,
                    modifiedAt: raw.lastModified
                )
            )
        }
        return results
    }

    private static func extractDecodedPath(from href: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPath: String
        if let url = URL(string: trimmed), url.scheme != nil {
            rawPath = url.path
        } else {
            rawPath = trimmed
        }
        return rawPath.removingPercentEncoding ?? rawPath
    }

    private static func normalizeDirPath(_ path: String) -> String {
        var p = path.isEmpty ? "/" : path
        if !p.hasPrefix("/") { p = "/" + p }
        if !p.hasSuffix("/") { p += "/" }
        return p
    }

    private static func normalizeFilePath(_ path: String) -> String {
        var p = path.isEmpty ? "/" : path
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = elementName.split(separator: ":").last.map { String($0).lowercased() } ?? elementName.lowercased()
        textBuffer = ""

        if local == "response" {
            currentItem = RawItem()
        } else if local == "resourcetype" {
            insideResourceType = true
        } else if local == "collection" && insideResourceType {
            currentItem?.isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = elementName.split(separator: ":").last.map { String($0).lowercased() } ?? elementName.lowercased()
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "href":
            if currentItem != nil && currentItem?.href.isEmpty == true {
                currentItem?.href = value
            }
        case "getcontentlength":
            if let len = Int64(value) {
                currentItem?.contentLength = len
            }
        case "getlastmodified":
            currentItem?.lastModified = Self.parseHTTPDate(value)
        case "resourcetype":
            insideResourceType = false
        case "response":
            if let item = currentItem {
                items.append(item)
            }
            currentItem = nil
        default:
            break
        }
        textBuffer = ""
    }
}

public final class WebDAVProvider: VFSProvider, @unchecked Sendable {
    public let scheme: String
    public let baseURL: URL
    private let username: String
    private let password: String
    private let userAgent: String
    private let redirectCache: WebDAVRedirectCache
    private let noRedirectDelegate: NoRedirectSessionDelegate
    private let session: URLSession

    public init(
        baseURL: URL,
        username: String = "",
        password: String = "",
        userAgent: String = "AuraTV/1.0",
        redirectCacheTTL: TimeInterval = 300
    ) {
        self.baseURL = baseURL
        self.scheme = baseURL.scheme?.lowercased() ?? "http"
        self.username = username
        self.password = password
        self.userAgent = userAgent
        self.redirectCache = WebDAVRedirectCache(defaultTTL: redirectCacheTTL)
        self.noRedirectDelegate = NoRedirectSessionDelegate()

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: cfg, delegate: noRedirectDelegate, delegateQueue: nil)
    }

    public func connect() async throws {
        _ = try await listDirectory(at: "/")
    }

    public func disconnect() async {
        await redirectCache.clearAll()
    }

    public func listDirectory(at path: String) async throws -> [VFSFileItem] {
        let targetURL = try buildURL(for: path, isDirectory: true)
        var req = makeAuthorizedRequest(url: targetURL, method: "PROPFIND", includeAuth: true)
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:resourcetype/>
            <D:getcontentlength/>
            <D:getlastmodified/>
          </D:prop>
        </D:propfind>
        """.utf8)

        let res = try await performHTTPRequest(session: session, request: req)
        if res.response.statusCode == 401 || res.response.statusCode == 403 {
            throw VFSError.authenticationFailed
        }
        if res.response.statusCode == 404 {
            throw VFSError.notFound(path)
        }
        guard (200...299).contains(res.response.statusCode) else {
            throw VFSError.httpError(statusCode: res.response.statusCode, message: "PROPFIND failed")
        }

        let parser = WebDAVPropfindParser()
        return try parser.parse(data: res.data, requestedPath: targetURL.path)
    }

    public func openStream(at path: String) async throws -> any VFSRandomAccessStream {
        let resolved = try await resolveDirectTarget(for: path, forceRefresh: false)
        return WebDAVRandomAccessStream(
            provider: self,
            path: path,
            totalSize: resolved.totalSize
        )
    }

    public func readFileData(at path: String, maxBytes: Int = 20 * 1024 * 1024) async throws -> Data {
        let resolved = try await resolveDirectTarget(for: path, forceRefresh: false)
        if resolved.totalSize > Int64(maxBytes) {
            throw VFSError.fileTooLarge(size: resolved.totalSize, maxBytes: maxBytes)
        }
        let isSameOrigin = isSameOriginAsBase(resolved.directURL)
        let req = makeAuthorizedRequest(url: resolved.directURL, method: "GET", includeAuth: isSameOrigin)
        let res = try await performHTTPRequest(session: session, request: req)
        guard (200...299).contains(res.response.statusCode) else {
            throw VFSError.httpError(statusCode: res.response.statusCode, message: "GET file failed")
        }
        if res.data.count > maxBytes {
            throw VFSError.fileTooLarge(size: Int64(res.data.count), maxBytes: maxBytes)
        }
        return res.data
    }

    internal struct ResolvedDirectTarget: Sendable {
        let directURL: URL
        let totalSize: Int64
    }

    internal func resolveDirectTarget(for path: String, forceRefresh: Bool) async throws -> ResolvedDirectTarget {
        if forceRefresh {
            await redirectCache.invalidate(for: path)
        }

        if let cached = await redirectCache.get(for: path) {
            let size = try await probeContentLength(url: cached)
            return ResolvedDirectTarget(directURL: cached, totalSize: size)
        }

        var currentURL = try buildURL(for: path, isDirectory: false)
        var hops = 0
        let maxHops = 5

        while hops <= maxHops {
            let includeAuth = isSameOriginAsBase(currentURL)
            var req = makeAuthorizedRequest(url: currentURL, method: "HEAD", includeAuth: includeAuth)
            let res = try await performHTTPRequest(session: session, request: req)
            let status = res.response.statusCode

            if [301, 302, 303, 307, 308].contains(status),
               let location = res.response.value(forHTTPHeaderField: "Location"),
               let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL {
                currentURL = nextURL
                hops += 1
                continue
            }

            if status == 401 || status == 403 {
                throw VFSError.authenticationFailed
            }
            if status == 404 {
                throw VFSError.notFound(path)
            }

            if status == 405 || status == 501 {
                req = makeAuthorizedRequest(url: currentURL, method: "GET", includeAuth: includeAuth)
                req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                let probe = try await performHTTPRequest(session: session, request: req)
                if [301, 302, 303, 307, 308].contains(probe.response.statusCode),
                   let location = probe.response.value(forHTTPHeaderField: "Location"),
                   let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL {
                    currentURL = nextURL
                    hops += 1
                    continue
                }
                guard (200...299).contains(probe.response.statusCode) else {
                    throw VFSError.httpError(statusCode: probe.response.statusCode, message: "Range probe failed")
                }
                let size = extractTotalSize(from: probe.response) ?? Int64(probe.data.count)
                if hops > 0 {
                    await redirectCache.set(currentURL, for: path)
                }
                return ResolvedDirectTarget(directURL: currentURL, totalSize: size)
            }

            guard (200...299).contains(status) else {
                throw VFSError.httpError(statusCode: status, message: "HEAD probe failed")
            }

            let size = extractTotalSize(from: res.response) ?? 0
            if hops > 0 {
                await redirectCache.set(currentURL, for: path)
            }
            return ResolvedDirectTarget(directURL: currentURL, totalSize: size)
        }

        throw VFSError.ioFailure("Too many HTTP redirects for \(path)")
    }

    internal func fetchRange(path: String, offset: Int64, length: Int, totalSize: Int64) async throws -> Data {
        guard length > 0, offset < totalSize else { return Data() }
        let endByte = min(totalSize - 1, offset + Int64(length) - 1)

        var url: URL
        if let cached = await redirectCache.get(for: path) {
            url = cached
        } else {
            url = try buildURL(for: path, isDirectory: false)
        }

        let firstAttempt = try await executeRangeGet(url: url, offset: offset, endByte: endByte)
        if let data = firstAttempt.data {
            return data
        }

        if [301, 302, 303, 307, 308, 401, 403, 404, 410].contains(firstAttempt.statusCode) {
            let refreshed = try await resolveDirectTarget(for: path, forceRefresh: true)
            let retry = try await executeRangeGet(url: refreshed.directURL, offset: offset, endByte: endByte)
            if let data = retry.data {
                return data
            }
            throw VFSError.httpError(statusCode: retry.statusCode, message: "Range GET failed after redirect refresh")
        }

        throw VFSError.httpError(statusCode: firstAttempt.statusCode, message: "Range GET failed")
    }

    private func executeRangeGet(url: URL, offset: Int64, endByte: Int64) async throws -> (data: Data?, statusCode: Int) {
        let includeAuth = isSameOriginAsBase(url)
        var req = makeAuthorizedRequest(url: url, method: "GET", includeAuth: includeAuth)
        req.setValue("bytes=\(offset)-\(endByte)", forHTTPHeaderField: "Range")
        let res = try await performHTTPRequest(session: session, request: req)
        let status = res.response.statusCode
        if status == 206 {
            return (res.data, status)
        }
        if status == 200 {
            let start = Int(min(Int64(res.data.count), offset))
            let end = Int(min(Int64(res.data.count), endByte + 1))
            if end >= start {
                let base = res.data.startIndex
                return (Data(res.data[(base + start)..<(base + end)]), status)
            }
            return (Data(), status)
        }
        return (nil, status)
    }

    private func probeContentLength(url: URL) async throws -> Int64 {
        let includeAuth = isSameOriginAsBase(url)
        let req = makeAuthorizedRequest(url: url, method: "HEAD", includeAuth: includeAuth)
        let res = try await performHTTPRequest(session: session, request: req)
        if let size = extractTotalSize(from: res.response) {
            return size
        }
        throw VFSError.httpError(statusCode: res.response.statusCode, message: "Unable to probe content length")
    }

    private func extractTotalSize(from response: HTTPURLResponse) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let slashIdx = contentRange.lastIndex(of: "/") {
            let totalStr = String(contentRange[contentRange.index(after: slashIdx)...]).trimmingCharacters(in: .whitespaces)
            if let total = Int64(totalStr) {
                return total
            }
        }
        if let lenHeader = response.value(forHTTPHeaderField: "Content-Length"),
           let len = Int64(lenHeader.trimmingCharacters(in: .whitespaces)) {
            return len
        }
        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        return nil
    }

    private func buildURL(for path: String, isDirectory: Bool) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw VFSError.invalidURL(baseURL.absoluteString)
        }

        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let cleanPath: String
        if path.hasPrefix(basePath) && !basePath.isEmpty && basePath != "/" {
            cleanPath = path
        } else {
            let sub = path.hasPrefix("/") ? path : "/" + path
            cleanPath = basePath + sub
        }

        var finalPath = cleanPath.isEmpty ? "/" : cleanPath
        if isDirectory && !finalPath.hasSuffix("/") {
            finalPath += "/"
        }
        components.path = finalPath

        guard let url = components.url else {
            throw VFSError.invalidURL(finalPath)
        }
        return url
    }

    private func isSameOriginAsBase(_ url: URL) -> Bool {
        url.scheme?.lowercased() == baseURL.scheme?.lowercased()
            && url.host?.lowercased() == baseURL.host?.lowercased()
            && url.port == baseURL.port
    }

    private func makeAuthorizedRequest(url: URL, method: String, includeAuth: Bool) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if includeAuth && !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
}

public final class WebDAVRandomAccessStream: VFSRandomAccessStream, @unchecked Sendable {
    private let provider: WebDAVProvider
    private let path: String
    public let totalSize: Int64

    internal init(provider: WebDAVProvider, path: String, totalSize: Int64) {
        self.provider = provider
        self.path = path
        self.totalSize = totalSize
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        try await provider.fetchRange(path: path, offset: offset, length: length, totalSize: totalSize)
    }

    public func close() async {}
}
