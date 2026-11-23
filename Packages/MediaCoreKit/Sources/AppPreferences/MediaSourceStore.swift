import Foundation
import NetworkVFS

/// Persists configured SMB/WebDAV network sources to local JSON.
/// Passwords are NEVER stored here; only `credentialKey` references for tvOS Keychain.
public actor MediaSourceStore {
    private let fileURL: URL
    private var sources: [MediaSourceConfig] = []
    private var isLoaded: Bool = false

    public init(storageDirectory: URL) {
        self.fileURL = storageDirectory.appendingPathComponent("sources.json")
    }

    public func allSources() throws -> [MediaSourceConfig] {
        try loadIfNeeded()
        return sources
    }

    public func source(id: UUID) throws -> MediaSourceConfig? {
        try loadIfNeeded()
        return sources.first { $0.id == id }
    }

    public func upsert(_ config: MediaSourceConfig) throws {
        try loadIfNeeded()
        if let idx = sources.firstIndex(where: { $0.id == config.id }) {
            sources[idx] = config
        } else {
            sources.append(config)
        }
        try persist()
    }

    public func delete(id: UUID) throws {
        try loadIfNeeded()
        sources.removeAll { $0.id == id }
        try persist()
    }

    public func replaceAll(with newSources: [MediaSourceConfig]) throws {
        sources = newSources
        isLoaded = true
        try persist()
    }

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        defer { isLoaded = true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            sources = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        sources = try JSONDecoder().decode([MediaSourceConfig].self, from: data)
    }

    private func persist() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sources)
        try data.write(to: fileURL, options: .atomic)
    }
}
