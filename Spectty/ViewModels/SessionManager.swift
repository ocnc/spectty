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
    private let sessionStore = MoshSessionStore()

    /// Mosh sessions available for resumption after app restart.
    private(set) var resumableSessions: [MoshSessionState] = []

    /// Tracks which ServerConnection UUID each session belongs to.
    private var sessionConnectionIDs: [UUID: String] = [:]

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
            transport = MoshTransport(config: config)
        }

        let scrollbackLines = UserDefaults.standard.integer(forKey: "scrollbackLines")
        let session = TerminalSession(
            connectionName: connection.name.isEmpty ? connection.host : connection.name,
            transport: transport,
            scrollbackCapacity: scrollbackLines > 0 ? scrollbackLines : 10_000
        )

        sessions.append(session)
        sessionConnectionIDs[session.id] = connection.id.uuidString
        activeSessionID = session.id

        try await session.start()

        return session
    }

    /// Disconnect and remove a session.
    func disconnect(_ session: TerminalSession) {
        session.stop()
        sessions.removeAll { $0.id == session.id }
        sessionConnectionIDs.removeValue(forKey: session.id)
        if activeSessionID == session.id {
            activeSessionID = sessions.last?.id
        }

        // Clean up any saved state for this session
        let sessionID = session.id.uuidString
        Task {
            await sessionStore.remove(sessionID: sessionID)
        }
    }

    /// Disconnect all sessions.
    func disconnectAll() {
        for session in sessions {
            session.stop()
        }
        sessions.removeAll()
        sessionConnectionIDs.removeAll()
        activeSessionID = nil
    }

    // MARK: - Session Resumption

    /// Load resumable mosh sessions from Keychain, filtering out stale ones.
    /// Server timeout is 600s; we filter at 550s to give a safety margin.
    func loadResumableSessions() async {
        let all = await sessionStore.loadAll()
        let cutoff = Date().addingTimeInterval(-550)
        resumableSessions = all.filter { $0.savedAt > cutoff }

        // Clean up stale sessions
        let stale = all.filter { $0.savedAt <= cutoff }
        for s in stale {
            await sessionStore.remove(sessionID: s.sessionID)
        }
    }

    /// Resume a saved mosh session.
    func resume(_ savedState: MoshSessionState) async throws -> TerminalSession {
        // Look up SSH password from Keychain by connectionID
        var password = ""
        let account = "password-\(savedState.connectionID)"
        if let data = try? await keychain.load(account: account) {
            password = String(data: data, encoding: .utf8) ?? ""
        }

        let config = SSHConnectionConfig(
            host: savedState.sshHost,
            port: savedState.sshPort,
            username: savedState.sshUsername,
            authMethod: .password(password)
        )

        let transport = MoshTransport(resuming: savedState, config: config)

        let scrollbackLines = UserDefaults.standard.integer(forKey: "scrollbackLines")
        let session = TerminalSession(
            connectionName: savedState.connectionName,
            transport: transport,
            scrollbackCapacity: scrollbackLines > 0 ? scrollbackLines : 10_000
        )

        sessions.append(session)
        sessionConnectionIDs[session.id] = savedState.connectionID
        activeSessionID = session.id

        // Remove from resumable list
        resumableSessions.removeAll { $0.sessionID == savedState.sessionID }
        await sessionStore.remove(sessionID: savedState.sessionID)

        do {
            try await session.start()
        } catch {
            // Clean up the session we just appended
            sessions.removeAll { $0.id == session.id }
            sessionConnectionIDs.removeValue(forKey: session.id)
            if activeSessionID == session.id {
                activeSessionID = sessions.last?.id
            }
            throw error
        }

        return session
    }

    /// Dismiss a resumable session (user swiped to remove).
    func dismissResumableSession(_ saved: MoshSessionState) async {
        resumableSessions.removeAll { $0.sessionID == saved.sessionID }
        await sessionStore.remove(sessionID: saved.sessionID)
    }

    /// Save all active mosh sessions for later resumption.
    /// Must complete synchronously (or await) before returning — iOS may
    /// suspend the app immediately after the scenePhase goes to .background.
    func saveActiveSessions() async {
        for session in sessions {
            guard let resumable = session.transport as? any ResumableTransport,
                  let connectionID = sessionConnectionIDs[session.id] else {
                continue
            }

            if let state = resumable.exportSessionState(
                sessionID: session.id.uuidString,
                connectionID: connectionID,
                connectionName: session.connectionName
            ) {
                try? await sessionStore.save(state)
            }
        }
    }
}
