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
}
