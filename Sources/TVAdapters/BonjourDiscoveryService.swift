import Foundation
import Network

/// A LAN host discovered through Bonjour/mDNS.
public struct DiscoveredLANHost: Identifiable, Hashable, Sendable {
    public let id: String
    public let serviceName: String
    public let protocolType: String
    public let hostName: String
    public let port: Int

    public init(
        id: String,
        serviceName: String,
        protocolType: String,
        hostName: String,
        port: Int
    ) {
        self.id = id
        self.serviceName = serviceName
        self.protocolType = protocolType
        self.hostName = hostName
        self.port = port
    }
}

/// Browses `_smb._tcp` / `_webdav._tcp` / `_webdavs._tcp` on the local link and
/// resolves each service to a hostname so the UI can prefill a source in one tap.
@MainActor
public final class BonjourDiscoveryService: NSObject, ObservableObject {
    @Published public private(set) var discoveredHosts: [DiscoveredLANHost] = []
    @Published public private(set) var isBrowsing: Bool = false

    private struct ServiceKind {
        let bonjourType: String
        let protocolType: String
        let defaultPort: Int
    }

    private static let kinds: [ServiceKind] = [
        ServiceKind(bonjourType: "_smb._tcp", protocolType: "smb", defaultPort: 445),
        ServiceKind(bonjourType: "_webdav._tcp", protocolType: "webdav", defaultPort: 80),
        ServiceKind(bonjourType: "_webdavs._tcp", protocolType: "webdav", defaultPort: 443)
    ]

    private var browsers: [NWBrowser] = []
    private var resolvers: [String: NetService] = [:]
    private var pending: [String: (serviceName: String, proto: String, port: Int, bonjourType: String)] = [:]
    private let queue = DispatchQueue(label: "auratv.bonjour.browser")

    public override init() {
        super.init()
    }

    public func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        for kind in Self.kinds {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjour(type: kind.bonjourType, domain: nil),
                using: parameters
            )
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let names: [String] = results.compactMap { result in
                    guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint else {
                        return nil
                    }
                    return name
                }
                guard !names.isEmpty else { return }
                Task { @MainActor in
                    self?.enqueue(names: names, kind: kind)
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        resolvers.values.forEach { $0.stop() }
        resolvers.removeAll()
        pending.removeAll()
        isBrowsing = false
    }

    private func enqueue(names: [String], kind: ServiceKind) {
        for name in names {
            let key = "\(kind.protocolType)|\(name)"
            if resolvers[key] != nil || pending[key] != nil { continue }
            if discoveredHosts.contains(where: { $0.id == key }) { continue }
            pending[key] = (name, kind.protocolType, kind.defaultPort, kind.bonjourType)

            let service = NetService(
                domain: "local.",
                type: "\(kind.bonjourType).",
                name: name
            )
            service.delegate = self
            service.resolve(withTimeout: 5)
            resolvers[key] = service
        }
    }

    private func resolveKey(serviceNamed name: String, serviceType: String) -> String? {
        pending.first { _, meta in
            meta.serviceName == name && serviceType.hasPrefix(meta.bonjourType)
        }?.key ?? pending.first { $0.value.serviceName == name }?.key
    }

    private func finishResolve(key: String, hostName: String, port: Int) {
        guard let meta = pending[key] else { return }
        resolvers[key]?.stop()
        resolvers[key] = nil
        pending[key] = nil

        let trimmed = hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = trimmed.isEmpty ? meta.serviceName : trimmed
        let resolvedPort = port > 0 ? port : meta.port
        if !discoveredHosts.contains(where: { $0.id == key }) {
            discoveredHosts.append(
                DiscoveredLANHost(
                    id: key,
                    serviceName: meta.serviceName,
                    protocolType: meta.proto,
                    hostName: host,
                    port: resolvedPort
                )
            )
        }
    }

    private func dropPending(key: String) {
        resolvers[key]?.stop()
        resolvers[key] = nil
        pending[key] = nil
    }
}

extension BonjourDiscoveryService: NetServiceDelegate {
    public nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let type = sender.type
        let host = sender.hostName ?? ""
        let port = sender.port
        Task { @MainActor [weak self] in
            guard let self, let key = self.resolveKey(serviceNamed: name, serviceType: type) else { return }
            self.finishResolve(key: key, hostName: host, port: port)
        }
    }

    public nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let name = sender.name
        let type = sender.type
        Task { @MainActor [weak self] in
            guard let self, let key = self.resolveKey(serviceNamed: name, serviceType: type) else { return }
            self.dropPending(key: key)
        }
    }
}
