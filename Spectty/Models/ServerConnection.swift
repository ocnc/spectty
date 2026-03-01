import Foundation
import SwiftData

/// Transport type for a server connection.
enum TransportType: String, Codable, CaseIterable, Sendable {
    case ssh = "SSH"
    case mosh = "Mosh"
}

/// Authentication method for connecting.
enum AuthMethod: String, Codable, CaseIterable, Sendable {
    case password = "Password"
    case publicKey = "Public Key"
    case keyboardInteractive = "Keyboard Interactive"

    /// Cases shown in the connection editor picker.
    /// `keyboardInteractive` is kept for SwiftData backwards compatibility
    /// but not offered in the UI (it behaves identically to `.password`).
    static let visibleCases: [AuthMethod] = [.password, .publicKey]
}

/// Lightweight Mosh preset for balancing defaults vs advanced behavior.
enum MoshPreset: String, Codable, CaseIterable, Sendable {
    case standard = "Standard"
    case strictNetwork = "Strict Network"
    case troubleshoot = "Troubleshoot"

    var summary: String {
        switch self {
        case .standard:
            return "Default settings for normal networks."
        case .strictNetwork:
            return "Prefers IPv4 and local IP resolution to reduce mixed-stack issues."
        case .troubleshoot:
            return "Disables PTY, forces IPv4, and uses remote-reported IP for maximum compatibility."
        }
    }
}

/// Address family to request for mosh-server bind (-i).
enum MoshBindFamilySetting: String, Codable, CaseIterable, Sendable {
    case automatic = "Automatic"
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
}

/// How UDP target IP is selected after bootstrap.
enum MoshIPResolutionSetting: String, Codable, CaseIterable, Sendable {
    case `default` = "Default"
    case local = "Local"
    case remote = "Remote"
}

/// Persistent model for a saved server connection.
@Model
final class ServerConnection {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var transport: TransportType
    var authMethod: AuthMethod

    /// Keychain account name for the stored password (if password auth).
    var passwordKeychainAccount: String?

    /// Keychain account name for the stored private key (if public key auth).
    var privateKeyKeychainAccount: String?

    /// Terminal profile name to use.
    var profileName: String?

    /// Last connected date.
    var lastConnected: Date?

    /// Command to run after connecting (e.g. "tmux new-session -A -s main").
    var startupCommand: String?

    /// Mosh UI preset for applying sensible defaults quickly.
    var moshPreset: MoshPreset = MoshPreset.standard

    /// Optional override path to `mosh-server` on remote host.
    var moshServerPath: String?

    /// Optional UDP port or range (e.g. "60001" or "60001:60010").
    var moshUDPPortRange: String?

    /// Compatibility mode: skips PTY for bootstrap.
    var moshCompatibilityMode: Bool = false

    /// Requested mosh-server bind address family.
    var moshBindFamily: MoshBindFamilySetting = MoshBindFamilySetting.automatic

    /// Host IP resolution strategy for UDP target selection.
    var moshIPResolution: MoshIPResolutionSetting = MoshIPResolutionSetting.default

    /// Sort order for the connection list.
    var sortOrder: Int

    /// Transient password — not persisted to SwiftData, only lives in memory
    /// for the duration of a session.
    @Transient
    var password: String = ""

    /// Transient private key PEM — not persisted to SwiftData, only lives in memory
    /// for the duration of an editing session.
    @Transient
    var privateKeyPEM: String = ""

    init(
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        transport: TransportType = .ssh,
        authMethod: AuthMethod = .password
    ) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.transport = transport
        self.authMethod = authMethod
        self.sortOrder = 0
    }

    /// Apply a preset and update related advanced Mosh settings.
    func applyMoshPreset(_ preset: MoshPreset) {
        moshPreset = preset
        switch preset {
        case .standard:
            moshCompatibilityMode = false
            moshBindFamily = .automatic
            moshIPResolution = .default
        case .strictNetwork:
            moshCompatibilityMode = false
            moshBindFamily = .ipv4
            moshIPResolution = .local
        case .troubleshoot:
            moshCompatibilityMode = true
            moshBindFamily = .ipv4
            moshIPResolution = .remote
        }
    }
}
