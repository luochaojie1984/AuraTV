import Foundation
import os
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

    public func connect() async throws {
        var cleanHost = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.lowercased().hasPrefix("smb://") {
            cleanHost = String(cleanHost.dropFirst("smb://".count))
        }
        while cleanHost.hasSuffix("/") {
            cleanHost.removeLast()
        }
        if !cleanHost.hasPrefix("[") && cleanHost.contains(":") {
            cleanHost = "[\(cleanHost)]"
        }

        let portSuffix = config.port.flatMap { $0 == 445 ? nil : ":\($0)" } ?? ""
        let urlString = "smb://\(cleanHost)\(portSuffix)"
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
            throw VFSError.ioFailure("connectShare(\(share)) failed: \(error.localizedDescription)")
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
            let shares = try await manager.listShares()
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
