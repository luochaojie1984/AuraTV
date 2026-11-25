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
        private struct State: Sendable {
            var finished = false
            var lastWaitingMessage: String?
            var timeoutTask: Task<Void, Never>?
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

        private func finish(
            _ continuation: CheckedContinuation<Void, any Error>,
            result: Result<Void, any Error>
        ) {
            let (shouldResume, taskToCancel) = lock.withLock { state -> (Bool, Task<Void, Never>?) in
                guard !state.finished else { return (false, nil) }
                state.finished = true
                let t = state.timeoutTask
                state.timeoutTask = nil
                return (true, t)
            }
            guard shouldResume else { return }
            taskToCancel?.cancel()
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(with: result)
        }

        func run(timeoutSeconds: TimeInterval) async throws {
            let timeoutNanos = UInt64(max(0.5, timeoutSeconds) * 1_000_000_000)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutNanos)
                    guard !Task.isCancelled else { return }
                    let waitingMsg = self.lock.withLock { $0.lastWaitingMessage }
                    let message: String
                    if let waitingMsg, !waitingMsg.isEmpty {
                        message = waitingMsg
                    } else {
                        message = "连接 \(self.host):\(self.port) 超时，请检查 IP 地址、端口及局域网连通性"
                    }
                    self.finish(continuation, result: .failure(VFSError.ioFailure(message)))
                }

                self.lock.withLock { $0.timeoutTask = timeoutTask }

                self.connection.stateUpdateHandler = { nwState in
                    switch nwState {
                    case .ready:
                        self.finish(continuation, result: .success(()))

                    case .waiting(let nwError):
                        let msg = AMSMB2Provider.describeNWError(nwError, host: self.host, port: self.port)
                        self.lock.withLock { state in
                            if !state.finished {
                                state.lastWaitingMessage = msg
                            }
                        }

                    case .failed(let nwError):
                        let msg = AMSMB2Provider.describeNWError(nwError, host: self.host, port: self.port)
                        self.finish(continuation, result: .failure(VFSError.ioFailure(msg)))

                    case .cancelled:
                        self.finish(continuation, result: .failure(VFSError.cancelled))

                    default:
                        break
                    }
                }

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
                return "无法建立到 \(host):\(port) 的本地网络连接（POSIX EPERM）"
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

    private static func classifySMBError(_ error: any Error, share: String?) -> VFSError {
        let rawDesc = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = rawDesc.isEmpty ? "未知 SMB 错误" : rawDesc
        let upper = label.uppercased()

        if upper.contains("STATUS_LOGON_FAILURE") || upper.contains("0XC000006D") || upper.contains("STATUS_WRONG_PASSWORD") {
            return .ioFailure("SMB 账号或密码错误（\(label)）。请点「编辑账号密码」核对用户名与密码并重新输入保存。")
        }
        if upper.contains("STATUS_ACCOUNT_RESTRICTION") || upper.contains("0XC000006E") || upper.contains("STATUS_ACCOUNT_LOCKED_OUT") {
            return .ioFailure("Windows 账号受限（\(label)），请检查服务器账号策略或密码设置。")
        }
        if upper.contains("STATUS_ACCESS_DENIED") || upper.contains("0XC0000022") {
            return .ioFailure("SMB 权限不足或拒绝访问（\(label)）。请核对账号共享权限，或在「路径 / 共享名」直接填写具体共享名（如 /Movies）。")
        }
        if upper.contains("STATUS_BAD_NETWORK_NAME") || upper.contains("0XC00000CC") {
            return .ioFailure("共享目录不存在（\(label)），请检查「路径 / 共享名」拼写。")
        }
        if let share {
            return .ioFailure("连接共享目录 \(share) 失败：\(label)")
        }
        return .ioFailure("读取根目录共享列表失败：\(label)。若服务器限制根目录枚举（IPC$），可点「编辑账号密码」并在「路径 / 共享名」直接填具体共享名（如 /Movies）。")
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
            domain = String(rawUser[..<slashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            username = String(rawUser[rawUser.index(after: slashIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let semiIndex = rawUser.firstIndex(of: ";") {
            domain = String(rawUser[..<semiIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            username = String(rawUser[rawUser.index(after: semiIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
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
            throw Self.classifySMBError(error, share: share)
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
                throw Self.classifySMBError(error, share: nil)
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
        do {
            let file = try await manager.openRandomAccessFile(shareName: resolved.share, atPath: resolved.relativePath)
            return AMSMB2RandomAccessStream(file: file)
        } catch {
            try await ensureShareConnected(resolved.share, using: manager, forceReconnect: true)
            do {
                let file = try await manager.openRandomAccessFile(shareName: resolved.share, atPath: resolved.relativePath)
                return AMSMB2RandomAccessStream(file: file)
            } catch {
                throw Self.classifySMBError(error, share: resolved.share)
            }
        }
    }

    /// Opens a dedicated persistent SMB file handle for synchronous FFmpeg AVIO scrubbing
    /// without loopback HTTP/TCP overhead or main playback stream lock contention.
    public func openSynchronousScrubReader(at path: String) async throws -> any SynchronousRandomAccessReader {
        let manager = try currentManager()
        guard let resolved = resolveShareAndRelativePath(path) else {
            throw VFSError.notFound(path)
        }
        try await ensureShareConnected(resolved.share, using: manager)
        do {
            let file = try await manager.openRandomAccessFile(shareName: resolved.share, atPath: resolved.relativePath)
            return SMB2SynchronousReader(file: file)
        } catch {
            try await ensureShareConnected(resolved.share, using: manager, forceReconnect: true)
            do {
                let file = try await manager.openRandomAccessFile(shareName: resolved.share, atPath: resolved.relativePath)
                return SMB2SynchronousReader(file: file)
            } catch {
                throw Self.classifySMBError(error, share: resolved.share)
            }
        }
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

/// Synchronous random-access reader contract used by direct FFmpeg AVIO scrubbing.
public protocol SynchronousRandomAccessReader: Sendable {
    var totalSize: Int64 { get }
    func readSync(offset: Int64, length: Int) throws -> Data
    func closeSync()
}

/// Persistent SMB2 synchronous reader backed by a dedicated `SMB2RandomAccessFile`.
public final class SMB2SynchronousReader: SynchronousRandomAccessReader, @unchecked Sendable {
    private let file: SMB2RandomAccessFile
    public var totalSize: Int64 { file.totalSize }

    public init(file: SMB2RandomAccessFile) {
        self.file = file
    }

    public func readSync(offset: Int64, length: Int) throws -> Data {
        try file.readSync(offset: offset, length: length)
    }

    public func closeSync() {
        file.close()
    }
}

/// Persistent random-access stream backed by a single open `SMB2RandomAccessFile`.
public final class AMSMB2RandomAccessStream: VFSRandomAccessStream, @unchecked Sendable {
    public var totalSize: Int64 { file.totalSize }
    private let file: SMB2RandomAccessFile
    private let closed = ManagedAtomicFlag()

    init(file: SMB2RandomAccessFile) {
        self.file = file
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        guard !closed.isSet else { throw VFSError.cancelled }
        guard offset >= 0, length >= 0 else {
            throw VFSError.invalidRange(offset: offset, length: length, totalSize: totalSize)
        }
        guard offset < totalSize, length > 0 else { return Data() }
        let capped = Int(min(Int64(length), totalSize - offset))
        try Task.checkCancellation()
        do {
            return try await file.read(offset: offset, length: capped)
        } catch is CancellationError {
            throw VFSError.cancelled
        } catch {
            if closed.isSet { throw VFSError.cancelled }
            throw VFSError.ioFailure("SMB read(\(offset)+\(capped)) failed: \(error.localizedDescription)")
        }
    }

    public func close() async {
        closed.set()
        file.close()
    }
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
    var isSet: Bool { lock.withLock { $0 } }
    func set() { lock.withLock { $0 = true } }
}
