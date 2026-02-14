import Foundation
import SpecttyTransport
import SpecttyKeychain

/// Manages active terminal sessions.
@Observable
@MainActor
final class SessionManager {
    private(set) var sessions: [TerminalSession] = []
    var activeSessionID: UUID?
    private let keychain = KeychainManager()

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionID }
    }

    /// Create and start a new session for a server connection.
    func connect(to connection: ServerConnection) async throws -> TerminalSession {
        // Resolve password: use transient value if set, otherwise load from Keychain.
        var password = connection.password
        if password.isEmpty, connection.authMethod == .password {
            let account = "password-\(connection.id.uuidString)"
            if let data = try? await keychain.load(account: account) {
                password = String(data: data, encoding: .utf8) ?? ""
            }
        }

        let config = SSHConnectionConfig(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            authMethod: .password(password)
        )

        let transport: any TerminalTransport

        switch connection.transport {
        case .ssh:
            transport = SSHTransport(config: config)
        case .mosh:
            transport = MoshTransport()
        }

        let scrollbackLines = UserDefaults.standard.integer(forKey: "scrollbackLines")
        let session = TerminalSession(
            connectionName: connection.name.isEmpty ? connection.host : connection.name,
            transport: transport,
            scrollbackCapacity: scrollbackLines > 0 ? scrollbackLines : 10_000
        )

        sessions.append(session)
        activeSessionID = session.id

        try await session.start()

        return session
    }

    /// Disconnect and remove a session.
    func disconnect(_ session: TerminalSession) {
        session.stop()
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.last?.id
        }
    }

    /// Disconnect all sessions.
    func disconnectAll() {
        for session in sessions {
            session.stop()
        }
        sessions.removeAll()
        activeSessionID = nil
    }
}
