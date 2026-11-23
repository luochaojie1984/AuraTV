import Foundation
import SwiftUI
import NetworkVFS
import SubtitleKit
import LocalStreamProxy
import AppPreferences

/// Single observable source of truth for the whole app.
@MainActor
public final class AppEnvironment: ObservableObject {
    public static let shared = AppEnvironment()

    public let settingsStore: AppSettingsStore
    public let sourceStore: MediaSourceStore
    public let historyStore: PlaybackHistoryStore
    public let proxy = LocalHTTPStreamProxy()

    @Published public private(set) var settings: AppSettings
    @Published public private(set) var sources: [MediaSourceConfig] = []
    @Published public private(set) var continueWatching: [PlaybackHistoryRecord] = []
    @Published public var proxyError: String?

    private init() {
        let directory = Self.storageDirectory()
        settingsStore = AppSettingsStore(storageDirectory: directory)
        sourceStore = MediaSourceStore(storageDirectory: directory)
        historyStore = PlaybackHistoryStore(storageDirectory: directory)
        settings = (try? settingsStore.load()) ?? AppSettings()
        reload()
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

    public func reload() {
        sources = (try? sourceStore.allSources()) ?? []
        continueWatching = (try? historyStore.continueWatching(limit: 20)) ?? []
        settings = (try? settingsStore.load()) ?? settings
    }

    public func upsert(source: MediaSourceConfig, password: String?) throws {
        try sourceStore.upsert(source)
        if let password, !password.isEmpty {
            try KeychainCredentialStore.savePassword(password, forKey: source.credentialKey)
        }
        reload()
    }

    public func delete(source: MediaSourceConfig) throws {
        try sourceStore.delete(id: source.id)
        KeychainCredentialStore.deletePassword(forKey: source.credentialKey)
        reload()
    }

    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        do {
            try settingsStore.save(next)
            settings = next
        } catch {
            proxyError = "设置保存失败：\(error.localizedDescription)"
        }
    }

    public func updateSubtitleStyle(_ mutate: @Sendable (inout SubtitleStyleConfig) -> Void) {
        do {
            let updated = try settingsStore.updateSubtitleStyle(mutate)
            settings.subtitleStyle = updated
        } catch {
            proxyError = "字幕样式保存失败：\(error.localizedDescription)"
        }
    }

    public func recordProgress(_ record: PlaybackHistoryRecord) {
        try? historyStore.recordProgress(record)
        continueWatching = (try? historyStore.continueWatching(limit: 20)) ?? continueWatching
    }

    /// Builds the right provider for a saved source.
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
