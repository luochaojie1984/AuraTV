import Foundation
import os
import AMSMB2
import NetworkVFS

/// SMB2/SMB3 provider backed by AMSMB2 (libsmb2).
///
/// Path semantics: `MediaSourceConfig.basePath` selects the share
/// (`/Movies` -> share `Movies`, root `/`). All VFS paths are relative to that
/// share root. When `basePath == "/"` the root listing returns share names.
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

    /// First path component of basePath, or nil when browsing share list.
    private var shareName: String? {
        let parts = config.basePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return parts.first
    }

    /// Strip the share prefix so all operations are share-relative.
    private func relativePath(_ path: String) -> String {
        let normalized = Self.nfc(path)
        guard let share = shareName else { return normalized.isEmpty ? "/" : normalized }
        let prefix = "/" + share
        if normalized == prefix { return "/" }
        if normalized.hasPrefix(prefix + "/") {
            return String(normalized.dropFirst(prefix.count))
        }
        return normalized.isEmpty ? "/" : normalized
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
        let portSuffix = config.port.map { ":\($0)" } ?? ""
        let urlString = "smb://\(config.host)\(portSuffix)"
        guard let url = URL(string: urlString) else {
            throw VFSError.invalidURL(urlString)
        }
        let credential = URLCredential(
            user: config.username,
            password: password,
            persistence: .forSession
        )
        guard let newManager = SMB2Manager(url: url, domain: "", credential: credential) else {
            throw VFSError.invalidURL(urlString)
        }
        stateLock.withLock {
            $0.manager = newManager
            $0.connectedShare = nil
        }

        if let share = shareName {
            try await connectShare(share, using: newManager)
        }
    }

    private func connectShare(_ share: String, using manager: SMB2Manager) async throws {
        do {
            try await manager.connectShare(name: share)
        } catch {
            throw VFSError.ioFailure("connectShare(\(share)) failed: \(error.localizedDescription)")
        }
        stateLock.withLock { $0.connectedShare = share }
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

        // Browsing the server root: enumerate shares instead of files.
        if shareName == nil, relativePath(path) == "/" {
            let shares = try await manager.listShares()
            return shares
                .filter { !$0.name.hasSuffix("$") }
                .map { share in
                    VFSFileItem(
                        id: Self.nfc("/" + share.name),
                        name: Self.nfc(share.name),
                        path: Self.nfc("/" + share.name),
                        isDirectory: true,
                        size: 0,
                        modifiedAt: nil
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        let target = relativePath(path)
        let entries: [[URLResourceKey: Any]]
        do {
            entries = try await manager.contentsOfDirectory(atPath: target)
        } catch {
            throw VFSError.ioFailure("contentsOfDirectory(\(target)) failed: \(error.localizedDescription)")
        }

        var items: [VFSFileItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries {
            guard let name = entry[.nameKey] as? String else { continue }
            // Hide metadata noise but keep normal dotfiles out of the browser.
            if name == "." || name == ".." { continue }
            guard let entryPath = entry[.pathKey] as? String else { continue }
            let isDirectory = (entry[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            let size = (entry[.fileSizeKey] as? Int64) ?? 0
            let modified = entry[.contentModificationDateKey] as? Date
            items.append(
                VFSFileItem(
                    id: Self.nfc(entryPath),
                    name: Self.nfc(name),
                    path: Self.nfc(entryPath),
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
        let target = relativePath(path)
        let attributes = try await manager.attributesOfItem(atPath: target)
        let size = (attributes[.fileSizeKey] as? Int64) ?? 0
        return AMSMB2RandomAccessStream(manager: manager, path: target, totalSize: size)
    }

    public func readFileData(at path: String, maxBytes: Int) async throws -> Data {
        let manager = try currentManager()
        let target = relativePath(path)
        return try await Self.read(manager: manager, path: target, offset: 0, length: maxBytes)
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
                buffer.append(chunk)
                if buffer.count >= length { break }
            }
        } catch {
            if error is CancellationError { throw VFSError.cancelled }
            throw VFSError.ioFailure("read(\(path), \(offset)+\(length)) failed: \(error.localizedDescription)")
        }
        if buffer.count > length { buffer = buffer.prefix(length) }
        return buffer
    }
}

/// Random-access stream over an AMSMB2 share. Each `read` is an independent
/// ranged request so a cancelled seek never poisons later reads.
public final class AMSMB2RandomAccessStream: VFSRandomAccessStream, @unchecked Sendable {
    public let totalSize: Int64
    private let manager: SMB2Manager
    private let path: String
    private let closed = ManagedAtomicFlag()

    init(manager: SMB2Manager, path: String, totalSize: Int64) {
        self.manager = manager
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
        return try await AMSMB2Provider.read(
            manager: manager,
            path: path,
            offset: offset,
            length: capped
        )
    }

    public func close() async {
        closed.set()
    }
}

/// Minimal atomic flag so the stream stays Sendable without importing Atomics.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)

    var isSet: Bool { lock.withLock { $0 } }

    func set() { lock.withLock { $0 = true } }
}
