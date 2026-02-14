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

    /// Sort order for the connection list.
    var sortOrder: Int

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
