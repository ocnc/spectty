import Foundation

/// Codable snapshot of a Mosh session for persistence and resumption.
/// Contains everything needed to reconnect UDP directly (skip SSH bootstrap).
public struct MoshSessionState: Codable, Sendable {
    public let sessionID: String
    public let connectionID: String       // ServerConnection UUID for auth lookup
    public let connectionName: String

    // Mosh session credentials (from bootstrap)
    public let host: String
    public let udpPort: Int
    public let key: String                // base64 AES-128 key

    // SSP sequence numbers
    public let senderCurrentNum: UInt64
    public let senderAckedNum: UInt64
    public let receiverCurrentNum: UInt64

    // SSH config for server-kill-on-disconnect
    public let sshHost: String
    public let sshPort: Int
    public let sshUsername: String

    // Auth method for resumption; nil defaults to password.
    public let authMethodType: SSHAuthMethodType?

    // Staleness check
    public let savedAt: Date

    public init(
        sessionID: String,
        connectionID: String,
        connectionName: String,
        host: String,
        udpPort: Int,
        key: String,
        senderCurrentNum: UInt64,
        senderAckedNum: UInt64,
        receiverCurrentNum: UInt64,
        sshHost: String,
        sshPort: Int,
        sshUsername: String,
        authMethodType: SSHAuthMethodType? = nil,
        savedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.host = host
        self.udpPort = udpPort
        self.key = key
        self.senderCurrentNum = senderCurrentNum
        self.senderAckedNum = senderAckedNum
        self.receiverCurrentNum = receiverCurrentNum
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUsername = sshUsername
        self.authMethodType = authMethodType
        self.savedAt = savedAt
    }
}
