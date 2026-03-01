import Foundation

/// Address family preference for `mosh-server new -i`.
public enum MoshBindFamily: String, Codable, Sendable {
    case automatic
    case ipv4
    case ipv6
}

/// Strategy for selecting the UDP target host after bootstrap.
public enum MoshIPResolution: String, Codable, Sendable {
    case `default`
    case local
    case remote
}

/// Bootstrap controls for Mosh connection setup.
public struct MoshBootstrapOptions: Sendable {
    /// Optional remote path for `mosh-server` binary.
    public var serverPath: String?

    /// Optional UDP port or range (e.g. "60001" or "60001:60010").
    public var udpPortRange: String?

    /// Whether to request an SSH PTY before running mosh-server.
    public var allocatePTY: Bool

    /// Requested bind family for mosh-server `-i`.
    public var bindFamily: MoshBindFamily

    /// UDP target IP selection strategy.
    public var ipResolution: MoshIPResolution

    public init(
        serverPath: String? = nil,
        udpPortRange: String? = nil,
        allocatePTY: Bool = true,
        bindFamily: MoshBindFamily = .automatic,
        ipResolution: MoshIPResolution = .default
    ) {
        self.serverPath = serverPath
        self.udpPortRange = udpPortRange
        self.allocatePTY = allocatePTY
        self.bindFamily = bindFamily
        self.ipResolution = ipResolution
    }
}
