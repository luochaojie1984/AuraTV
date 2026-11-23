import Foundation
import NetworkVFS

public struct LocalStreamProxyInfo: Sendable, Equatable {
    public let version: String

    public init(version: String = "0.1.0-phase0") {
        self.version = version
    }
}
