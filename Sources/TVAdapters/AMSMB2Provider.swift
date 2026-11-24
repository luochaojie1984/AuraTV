import Foundation
import os
import Network
import AMSMB2
import NetworkVFS

/// SMB2/SMB3 provider backed by AMSMB2 (libsmb2).
///
/// Supports all 3 source configurations cleanly:
/// 1. `basePath == "/"` (e.g. Bonjour auto-discovered host): root lists shares (`/Movies`, `/Series`);
///    navigating into `/Movies/...` dynamically connects share `Movies` and strips the `/Movies` prefix.
/// 2. `basePath == "/Movies"`: connects share `Movies` upfront; browsing `/` lists share root.
/// 3. `basePath == "/Media/Movies"`: connects share `Media` upfront and roots browsing at `/Movies`.
public final class AMSMB2Provider: VFSProvider, @unchecked Sendable {
    public let scheme = "smb"

    private let config: MediaSourceConfig
    private let password: String

    private struct ConnectionState {
        var manager: SMB2Manager?
        var connectedShare: String?
    }

    private let stateLock = OSAllocatedUnfairLock<ConnectionState>(initialState: ConnectionState())

    public init(config: MediaSourceConfig, password: String) {
        self.config = config
        self.password = password
    }

    private var configuredBaseParts: [String] {
        Self.nfc(config.basePath)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Configured share name from `basePath`, or `nil` when browsing server share list (`basePath == "/"`).
    private var configuredShareName: String? {
        configuredBaseParts.first
    }

    /// Subpath inside the configured share (e.g. `"/Movies"` when `basePath == "/Media/Movies"`), or `""`.
    private var configuredShareSubpath: String {
        let parts = configuredBaseParts
        guard parts.count > 1 else { return "" }
        return "/" + parts.dropFirst().joined(separator: "/")
    }

    private static func nfc(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    private func currentManager() throws -> SMB2Manager {
        let manager = stateLock.withLock { $0.manager }
        guard let manager else { throw VFSError.notConnected }
        return manager
    }

    private static func parseHostAndPort(rawHost: String, configuredPort: Int?) -> (networkHost: String, urlHost: String, effectivePort: Int?) {
        var clean = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("smb://") {
            clean = String(clean.dropFirst("smb://".count))
        }
        while clean.hasSuffix("/") {
            clean.removeLast()
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)

        var networkHost = clean
        var urlHost = clean
        var inlinePort: Int?

        if clean.hasPrefix("["), let closeIdx = clean.firstIndex(of: "]") {
            let inside = String(clean[clean.index(after: clean.startIndex)..<closeIdx])
            let after = clean[clean.index(after: closeIdx)...]
            if after.hasPrefix(":"), let p = Int(after.dropFirst()), (1...65535).contains(p) {
                inlinePort = p
            }
            networkHost = inside
            urlHost = "[\(inside)]"
        } else {
            let colonCount = clean.filter { $0 == ":" }.count
            if colonCount == 1, let idx = clean.firstIndex(of: ":") {
                let hostPart = String(clean[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                let portPart = String(clean[clean.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !hostPart.isEmpty, let p = Int(portPart), (1...65535).contains(p) {
                    networkHost = hostPart
                    urlHost = hostPart
                    inlinePort = p
                }
            } else if colonCount >= 2 {
                networkHost = clean
                urlHost = "[\(clean)]"
            }
        }

        return (networkHost, urlHost, configuredPort ?? inlinePort)
    }

    private final class TCPPreflightCoordinator: @unchecked Sendable {
        private struct State {
            var finished = false
            var lastWaitingMessage: String?
            var timeoutItem: DispatchWorkItem?
        }

        private let lock = OSAllocatedUnfairLock<State>(initialState: State())
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "auratv.smb.preflight")
        private let host: String
        private let port: Int

        init(host: String, port: Int, nwPort: NWEndpoint.Port) {
            self.host = host
            self.port = port
            self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        }

        func run(timeoutSeconds: TimeInterval) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let waitingMsg: String? = self.lock.withLock { state in
                        guard !state.finished else { return nil }
                        state.finished = true
                        state.timeoutItem = nil
                        return state.lastWaitingMessage ?? ""
                    }
                    guard let waitingMsg else { return }
                    self.connection.cancel()
                    let message = waitingMsg.isEmpty
                        ? "连接 \(self.host):\(self.port) 超时，请检查 IP 地址、端口及局域网连通性（以及 Apple TV「设置 → 隐私与安全性 → 本地网络」中 AuraTV 权限）"
                        : waitingMsg
                    continuation.resume(throwing: VFSError.ioFailure(message))
                }

                self.lock.withLock { $0.timeoutItem = work }

                self.connection.stateUpdateHandler = { [weak self] nwState in
                    guard let self else { return }
                    switch nwState {
                    case .ready:
                        let (shouldResume, itemToCancel) = self.lock.withLock { state -> (Bool, DispatchWorkItem?) in
                            guard !state.finished else { return (false, nil) }
                            state.finished = true
                            let item = state.timeoutItem
                            state.timeoutItem = nil
                            return (true, item)
                        }
                        guard shouldResume else { return }
                        itemToCancel?.cancel()
                        self.connection.cancel()
                        continuation.resume()

                    case .waiting(let nwError):
                        let msg = AMSMB2Provider.describeNWError(nwError, host: self.host, port: self.port)
                        self.lock.withLock { state in
                            if !state.finished {
                                state.lastWaitingMessage = msg
                            }
                        }

                    case .failed(let nwError):
                        let (shouldResume, itemToCancel) = self.lock.withLock { state -> (Bool, DispatchWorkItem?) in
                            guard !state.finished else { return (false, nil) }
                            state.finished = true
                            let item = state.timeoutItem
                            state.timeoutItem = nil
                            return (true, item)
                        }
                        guard shouldResume else { return }
                        itemToCancel?.cancel()
                        self.connection.cancel()
                        let msg = AMSMB2Provider.describeNWError(nwError, host: self.host, port: self.port)
                        continuation.resume(throwing: VFSError.ioFailure(msg))

                    case .cancelled:
                        let (shouldResume, itemToCancel) = self.lock.withLock { state -> (Bool, DispatchWorkItem?) in
                            guard !state.finished else { return (false, nil) }
                            state.finished = true
                            let item = state.timeoutItem
                            state.timeoutItem = nil
                            return (true, item)
                        }
                        if shouldResume {
                            itemToCancel?.cancel()
                            continuation.resume(throwing: VFSError.cancelled)
                        }

                    default:
                        break
                    }
                }

                self.queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
                self.connection.start(queue: self.queue)
            }
        }
    }

    private static func preflightTCP(host: String, port: Int, timeoutSeconds: TimeInterval = 6.0) async throws {
        guard !host.isEmpty,
              (1...65535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw VFSError.invalidURL("smb://\(host):\(port)")
        }
        let coordinator = TCPPreflightCoordinator(host: host, port: port, nwPort: nwPort)
        try await coordinator.run(timeoutSeconds: timeoutSeconds)
    }

    private static func describeNWError(_ error: NWError, host: String, port: Int) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .EPERM:
                return "Apple TV 本地网络权限未开启（EPERM），请到 Apple TV「设置 → 隐私与安全性 → 本地网络」中开启 AuraTV 权限后重试"
            case .ECONNREFUSED:
                return "目标主机 \(host):\(port) 拒绝连接（请确认已开启 SMB 文件共享且防火墙放行 \(port) 端口）"
            case .EHOSTUNREACH, .ENETUNREACH:
                return "无法路由到 \(host)（请确认 Apple TV 与服务器在同一局域网且 IP 正确）"
            default:
                return "TCP 连接 \(host):\(port) 失败：\(error.localizedDescription) (POSIX \(code.rawValue))"
            }
        case .dns(let dnsError):
            return "无法解析主机名 \(host)（DNS 错误 \(dnsError)），请改填局域网 IP 地址重试"
        default:
            return "TCP 连接 \(host):\(port) 失败：\(error.localizedDescription)"
        }
    }

    private static func extractPOSIXCode(from error: any Error) -> Int32? {
        if let posix = error as? POSIXError {
            return Int32(posix.code.rawValue)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        return nil
    }

    private static func classifyListSharesError(_ error: any Error) -> VFSError {
        let rawDesc = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = extractPOSIXCode(from: error)
        if code == 1 || rawDesc.isEmpty || rawDesc == "Error code 1:" || rawDesc.hasPrefix("Error code 1:") {
            let label = rawDesc.isEmpty ? "Error code 1" : rawDesc
            return .ioFailure("SMB 认证或根目录共享枚举被断开（\(label)）。请检查：① 用户名与密码是否正确；② 若服务器限制根目录枚举（IPC$），请点「编辑账号密码」并在「路径 / 共享名」直接填具体共享文件夹名（如 /Movies）；③ 确认 Apple TV「设置 → 隐私与安全性 → 本地网络」已允许 AuraTV。")
        }
        if code == 13 || rawDesc.localizedCaseInsensitiveContains("ACCESS_DENIED") || rawDesc.localizedCaseInsensitiveContains("LOGON_FAILURE") {
            return .ioFailure("SMB 账号密码验证失败或无访问权限（\(rawDesc)），请点击「编辑账号密码」核对凭据。")
        }
        return .ioFailure("读取根目录共享列表失败：\(rawDesc)")
    }

    public func connect() async throws {
        let parsed = Self.parseHostAndPort(rawHost: config.host, configuredPort: config.port)
        let tcpPort = parsed.effectivePort ?? 445

        // Triggers tvOS Local Network authorization cleanly and surfaces clear socket errors before libsmb2 calls.
        try await Self.preflightTCP(host: parsed.networkHost, port: tcpPort)

        let portSuffix = parsed.effectivePort.flatMap { $0 == 445 ? nil : ":\($0)" } ?? ""
        let urlString = "smb://\(parsed.urlHost)\(portSuffix)"
        guard let url = URL(string: urlString) else {
            throw VFSError.invalidURL(urlString)
        }

        let rawUser = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain: String
        let username: String
        if let slashIndex = rawUser.firstIndex(of: "\\") {
            domain = String(rawUser[..<slashIndex])
            username = String(rawUser[rawUser.index(after: slashIndex)...])
        } else {
            domain = ""
            username = rawUser
        }

        let credential: URLCredential? = username.isEmpty
            ? nil
            : URLCredential(user: username, password: password, persistence: .forSession)

        guard let newManager = SMB2Manager(url: url, domain: domain, credential: credential) else {
            throw VFSError.invalidURL(urlString)
        }
        stateLock.withLock {
            $0.manager = newManager
            $0.connectedShare = nil
        }

        if let share = configuredShareName {
            try await ensureShareConnected(share, using: newManager)
        }
    }

    private func ensureShareConnected(_ share: String, using manager: SMB2Manager, forceReconnect: Bool = false) async throws {
        let alreadyConnected = stateLock.withLock { $0.connectedShare == share }
        if alreadyConnected && !forceReconnect {
            return
        }
        do {
            try await manager.connectShare(name: share)
        } catch {
            let rawDesc = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = Self.extractPOSIXCode(from: error)
            if code == 1 || rawDesc.isEmpty || rawDesc == "Error code 1:" || rawDesc.hasPrefix("Error code 1:") {
                let label = rawDesc.isEmpty ? "Error code 1" : rawDesc
                throw VFSError.ioFailure("连接共享目录 \(share) 失败（\(label)）。请检查：① 用户名与密码是否正确；② 共享名称（\(share)）是否存在且当前账号有权限访问；③ Apple TV「设置 → 隐私与安全性 → 本地网络」已开启 AuraTV 权限。")
            }
            throw VFSError.ioFailure("连接共享目录 \(share) 失败：\(rawDesc)")
        }
        stateLock.withLock { $0.connectedShare = share }
    }

    /// Resolves a VFS virtual path into `(shareName, shareRelativePath)`.
    /// Returns `nil` only when browsing the top-level share list (`basePath == "/"` and `path == "/"`).
    private func resolveShareAndRelativePath(_ rawPath: String) -> (share: String, relativePath: String, virtualPrefix: String)? {
        let normalized = Self.nfc(rawPath)
        let pathParts = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        if let fixedShare = configuredShareName {
            // Strip fixedShare prefix if caller passed full `/Share/...` path
            var relParts = pathParts
            if relParts.first == fixedShare {
                relParts.removeFirst()
            }
            let baseSub = configuredShareSubpath
            let rel: String
            if relParts.isEmpty {
                rel = baseSub.isEmpty ? "/" : baseSub
            } else {
                let joined = "/" + relParts.joined(separator: "/")
                if !baseSub.isEmpty && !joined.hasPrefix(baseSub) {
                    rel = baseSub + joined
                } else {
                    rel = joined
                }
            }
            return (fixedShare, rel, "")
        } else {
            // Multi-share mode (`basePath == "/"`): first path component IS the share name
            guard let first = pathParts.first else {
                return nil // Browsing server share list `/`
            }
            let rest = pathParts.dropFirst()
            let rel = rest.isEmpty ? "/" : ("/" + rest.joined(separator: "/"))
            return (first, rel, "/\(first)")
        }
    }

    public func disconnect() async {
        let manager = stateLock.withLock { state -> SMB2Manager? in
            let current = state.manager
            state.manager = nil
            state.connectedShare = nil
            return current
        }
        try? await manager?.disconnectShare()
    }

    public func listDirectory(at path: String) async throws -> [VFSFileItem] {
        let manager = try currentManager()

        guard let resolved = resolveShareAndRelativePath(path) else {
            // Server root: enumerate SMB shares
            let shares: [(name: String, comment: String)]
            do {
                shares = try await manager.listShares()
            } catch {
                throw Self.classifyListSharesError(error)
            }
            return shares
                .filter { !$0.name.hasSuffix("$") }
                .map { share in
                    let cleanName = Self.nfc(share.name)
                    return VFSFileItem(
                        id: "/\(cleanName)",
                        name: cleanName,
                        path: "/\(cleanName)",
                        isDirectory: true,
                        size: 0,
                        modifiedAt: nil
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        try await ensureShareConnected(resolved.share, using: manager)

        let entries: [[URLResourceKey: Any]]
        do {
            entries = try await manager.contentsOfDirectory(atPath: resolved.relativePath)
        } catch {
            // Retry once after reconnecting share (handles idle SMB server disconnects)
            try await ensureShareConnected(resolved.share, using: manager, forceReconnect: true)
            do {
                entries = try await manager.contentsOfDirectory(atPath: resolved.relativePath)
            } catch {
                throw VFSError.ioFailure("contentsOfDirectory(\(resolved.share):\(resolved.relativePath)) failed: \(error.localizedDescription)")
            }
        }

        var items: [VFSFileItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries {
            guard let name = entry[.nameKey] as? String else { continue }
            if name == "." || name == ".." { continue }
            guard let entryPath = entry[.pathKey] as? String else { continue }
            let isDirectory = (entry[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            let size = (entry[.fileSizeKey] as? Int64) ?? 0
            let modified = entry[.contentModificationDateKey] as? Date

            let cleanEntryPath = entryPath.hasPrefix("/") ? entryPath : "/" + entryPath
            let fullVirtualPath = Self.nfc(resolved.virtualPrefix + cleanEntryPath)
            items.append(
                VFSFileItem(
                    id: fullVirtualPath,
                    name: Self.nfc(name),
                    path: fullVirtualPath,
                    isDirectory: isDirectory,
                    size: size,
                    modifiedAt: modified
                )
            )
        }
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func openStream(at path: String) async throws -> any VFSRandomAccessStream {
        let manager = try currentManager()
        guard let resolved = resolveShareAndRelativePath(path) else {
            throw VFSError.notFound(path)
        }
        try await ensureShareConnected(resolved.share, using: manager)
        let attributes = try await manager.attributesOfItem(atPath: resolved.relativePath)
        let size = (attributes[.fileSizeKey] as? Int64) ?? 0
        return AMSMB2RandomAccessStream(
            provider: self,
            manager: manager,
            share: resolved.share,
            path: resolved.relativePath,
            totalSize: size
        )
    }

    public func readFileData(at path: String, maxBytes: Int) async throws -> Data {
        let manager = try currentManager()
        guard let resolved = resolveShareAndRelativePath(path) else {
            throw VFSError.notFound(path)
        }
        try await ensureShareConnected(resolved.share, using: manager)
        return try await readWithReconnect(manager: manager, share: resolved.share, path: resolved.relativePath, offset: 0, length: maxBytes)
    }

    func readWithReconnect(
        manager: SMB2Manager,
        share: String,
        path: String,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        do {
            return try await Self.read(manager: manager, path: path, offset: offset, length: length)
        } catch let err as VFSError where err == .cancelled {
            throw err
        } catch {
            try Task.checkCancellation()
            try await ensureShareConnected(share, using: manager, forceReconnect: true)
            return try await Self.read(manager: manager, path: path, offset: offset, length: length)
        }
    }

    static func read(
        manager: SMB2Manager,
        path: String,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        guard length > 0 else { return Data() }
        let upper = offset + Int64(length)
        var buffer = Data()
        buffer.reserveCapacity(length)
        do {
            for try await chunk in manager.contents(atPath: path, range: offset..<upper) {
                try Task.checkCancellation()
                buffer.append(chunk)
                if buffer.count >= length { break }
            }
        } catch {
            if error is CancellationError { throw VFSError.cancelled }
            throw VFSError.ioFailure("read(\(path), \(offset)+\(length)) failed: \(error.localizedDescription)")
        }
        if buffer.count > length {
            buffer = Data(buffer.prefix(length))
        }
        return buffer
    }
}

/// Random-access stream over an AMSMB2 share.
public final class AMSMB2RandomAccessStream: VFSRandomAccessStream, @unchecked Sendable {
    public let totalSize: Int64
    private let provider: AMSMB2Provider
    private let manager: SMB2Manager
    private let share: String
    private let path: String
    private let closed = ManagedAtomicFlag()

    init(provider: AMSMB2Provider, manager: SMB2Manager, share: String, path: String, totalSize: Int64) {
        self.provider = provider
        self.manager = manager
        self.share = share
        self.path = path
        self.totalSize = totalSize
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        guard !closed.isSet else { throw VFSError.cancelled }
        guard offset >= 0, length >= 0 else {
            throw VFSError.invalidRange(offset: offset, length: length, totalSize: totalSize)
        }
        guard offset < totalSize else { return Data() }
        let capped = Int(min(Int64(length), totalSize - offset))
        try Task.checkCancellation()
        return try await provider.readWithReconnect(
            manager: manager,
            share: share,
            path: path,
            offset: offset,
            length: capped
        )
    }

    public func close() async {
        closed.set()
    }
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
    var isSet: Bool { lock.withLock { $0 } }
    func set() { lock.withLock { $0 = true } }
}
