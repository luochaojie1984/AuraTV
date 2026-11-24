import Foundation
import SwiftUI
import NetworkVFS
import SubtitleKit
import LocalStreamProxy
import AppPreferences

/// Single observable source of truth for the whole app.
/// Maintains persisted settings/sources/history AND a warm LAN VFSProvider connection pool
/// so connected SMB/WebDAV/Bonjour servers stay remembered and ready without reconnecting.
@MainActor
public final class AppEnvironment: ObservableObject {
    public static let shared = AppEnvironment()

    public let settingsStore: AppSettingsStore
    public let sourceStore: MediaSourceStore
    public let historyStore: PlaybackHistoryStore
    public let proxy = LocalHTTPStreamProxy()

    @Published public private(set) var settings = AppSettings()
    @Published public private(set) var sources: [MediaSourceConfig] = []
    @Published public private(set) var continueWatching: [PlaybackHistoryRecord] = []
    @Published public private(set) var historyByKey: [String: PlaybackHistoryRecord] = [:]
    @Published public private(set) var connectedSourceIDs: Set<UUID> = []
    @Published public var proxyError: String?

    private var providerPool: [UUID: any VFSProvider] = [:]
    private var bootstrapped = false

    private init() {
        let directory = Self.storageDirectory()
        settingsStore = AppSettingsStore(storageDirectory: directory)
        sourceStore = MediaSourceStore(storageDirectory: directory)
        historyStore = PlaybackHistoryStore(storageDirectory: directory)
        do {
            try proxy.start()
        } catch {
            proxyError = error.localizedDescription
        }
    }

    public static func storageDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AuraTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Loads persisted state once and silently pre-connects remembered LAN sources in background.
    public func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await reload()
        Task { await self.preconnectSavedSources() }
    }

    public func reload() async {
        sources = (try? await sourceStore.allSources()) ?? []
        continueWatching = (try? await historyStore.continueWatching(limit: 20)) ?? []
        let allHistory = (try? await historyStore.allRecords()) ?? []
        var map: [String: PlaybackHistoryRecord] = [:]
        map.reserveCapacity(allHistory.count)
        for rec in allHistory {
            map[rec.id] = rec
        }
        historyByKey = map
        if let loaded = try? await settingsStore.load() {
            settings = loaded
            UISoundPlayer.shared.isEnabled = loaded.enableUISoundEffects
        }
    }

    public func upsert(source: MediaSourceConfig, password: String?) async throws {
        try await sourceStore.upsert(source)
        if let password, !password.isEmpty {
            try KeychainCredentialStore.savePassword(password, forKey: source.credentialKey)
        }
        await invalidateCachedProvider(for: source.id)
        await reload()
        Task { _ = try? await self.connectedProvider(for: source) }
    }

    public func delete(source: MediaSourceConfig) async throws {
        await invalidateCachedProvider(for: source.id)
        try await sourceStore.delete(id: source.id)
        KeychainCredentialStore.deletePassword(forKey: source.credentialKey)
        await updateSettings { $0.lastVisitedPaths.removeValue(forKey: source.id.uuidString) }
        await reload()
    }

    /// Automatically remembers any Bonjour-discovered LAN host without creating duplicates.
    public func rememberDiscoveredHost(_ host: DiscoveredLANHost) async -> MediaSourceConfig {
        let proto: MediaSourceProtocol = host.protocolType == "smb" ? .smb : .webdav
        let normalizedHost = host.hostName.lowercased()
        if let existing = sources.first(where: {
            $0.protocolType == proto && $0.host.lowercased() == normalizedHost
        }) {
            return existing
        }

        let config = MediaSourceConfig(
            displayName: host.serviceName,
            protocolType: proto,
            host: host.hostName,
            port: host.port,
            useTLS: proto == .webdav && host.port == 443,
            basePath: "/"
        )
        try? await sourceStore.upsert(config)
        await reload()
        return config
    }

    public func isDiscoveredHostRemembered(_ host: DiscoveredLANHost) -> Bool {
        let proto: MediaSourceProtocol = host.protocolType == "smb" ? .smb : .webdav
        let normalizedHost = host.hostName.lowercased()
        return sources.contains { $0.protocolType == proto && $0.host.lowercased() == normalizedHost }
    }

    public func updateSettings(_ mutate: @Sendable (inout AppSettings) -> Void) async {
        var next = settings
        mutate(&next)
        do {
            try await settingsStore.save(next)
            settings = next
            UISoundPlayer.shared.isEnabled = next.enableUISoundEffects
        } catch {
            proxyError = "设置保存失败：\(error.localizedDescription)"
        }
    }

    public func updateSubtitleStyle(_ mutate: @Sendable (inout SubtitleStyleConfig) -> Void) async {
        do {
            let updated = try await settingsStore.updateSubtitleStyle(mutate)
            settings.subtitleStyle = updated
        } catch {
            proxyError = "字幕样式保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Remembered LAN Folders

    public func lastVisitedPath(for sourceID: UUID) -> String {
        settings.lastVisitedPaths[sourceID.uuidString] ?? "/"
    }

    public func rememberVisitedPath(_ path: String, for sourceID: UUID) {
        let key = sourceID.uuidString
        guard settings.lastVisitedPaths[key] != path else { return }
        Task {
            await updateSettings { $0.lastVisitedPaths[key] = path }
        }
    }

    // MARK: - Playback Resume Memory (记忆播放)

    public func recordProgress(_ record: PlaybackHistoryRecord) async {
        guard settings.enableResumePlayback else { return }
        try? await historyStore.recordProgress(record)
        historyByKey[record.id] = record
        continueWatching = (try? await historyStore.continueWatching(limit: 20)) ?? continueWatching
    }

    public func resumePosition(for sourceID: UUID, filePath: String) -> TimeInterval {
        guard settings.enableResumePlayback else { return 0 }
        let key = PlaybackHistoryRecord.makeKey(sourceID: sourceID, filePath: filePath)
        guard let record = historyByKey[key], !record.isWatched, record.lastPositionSeconds >= 5 else {
            return 0
        }
        return record.lastPositionSeconds
    }

    public func historyRecord(for sourceID: UUID, filePath: String) -> PlaybackHistoryRecord? {
        guard settings.enableResumePlayback else { return nil }
        return historyByKey[PlaybackHistoryRecord.makeKey(sourceID: sourceID, filePath: filePath)]
    }

    public func clearPlaybackHistory() async {
        try? await historyStore.clearAll()
        historyByKey.removeAll()
        continueWatching.removeAll()
    }

    // MARK: - Warm Persistent LAN Connection Pool

    public func connectedProvider(for source: MediaSourceConfig, forceReconnect: Bool = false) async throws -> any VFSProvider {
        if !forceReconnect, let cached = providerPool[source.id] {
            return cached
        }
        if let old = providerPool.removeValue(forKey: source.id) {
            connectedSourceIDs.remove(source.id)
            await old.disconnect()
        }
        guard let provider = makeProvider(for: source) else {
            throw VFSError.invalidURL(source.host)
        }
        try await provider.connect()
        providerPool[source.id] = provider
        connectedSourceIDs.insert(source.id)
        return provider
    }

    public func invalidateCachedProvider(for sourceID: UUID) async {
        connectedSourceIDs.remove(sourceID)
        if let existing = providerPool.removeValue(forKey: sourceID) {
            await existing.disconnect()
        }
    }

    public func preconnectSavedSources() async {
        let snapshot = sources
        for source in snapshot {
            if providerPool[source.id] != nil { continue }
            _ = try? await connectedProvider(for: source)
        }
    }

    /// Builds a fresh VFSProvider for a saved source.
    public func makeProvider(for source: MediaSourceConfig) -> (any VFSProvider)? {
        switch source.protocolType {
        case .smb:
            let password = KeychainCredentialStore.password(forKey: source.credentialKey) ?? ""
            return AMSMB2Provider(config: source, password: password)
        case .webdav:
            var components = URLComponents()
            components.scheme = source.useTLS ? "https" : "http"
            components.host = source.host
            components.port = source.port
            components.path = source.basePath
            guard let url = components.url else { return nil }
            let password = KeychainCredentialStore.password(forKey: source.credentialKey) ?? ""
            return WebDAVProvider(
                baseURL: url,
                username: source.username,
                password: password
            )
        }
    }
}
