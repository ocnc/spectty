import Foundation
import CryptoKit
import NIOSSH
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

    /// Tracks which ServerConnection UUID each session belongs to.
    private var sessionConnectionIDs: [UUID: String] = [:]

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionID }
    }

    // MARK: - Session Navigation

    var activeSessionIndex: Int? {
        sessions.firstIndex(where: { $0.id == activeSessionID })
    }

    var hasNextSession: Bool { nextSession() != nil }
    var hasPreviousSession: Bool { previousSession() != nil }

    func nextSession() -> TerminalSession? {
        guard let index = activeSessionIndex, index + 1 < sessions.count else { return nil }
        return sessions[index + 1]
    }

    func previousSession() -> TerminalSession? {
        guard let index = activeSessionIndex, index - 1 >= 0 else { return nil }
        return sessions[index - 1]
    }

    /// Resize all sessions to the current grid size.
    /// Keeps background sessions in sync so switching never triggers a resize.
    func resizeAllSessions(columns: Int, rows: Int) {
        for session in sessions {
            session.resize(columns: columns, rows: rows)
        }
    }

    func switchToNext() {
        if let next = nextSession() { activeSessionID = next.id }
    }

    func switchToPrevious() {
        if let prev = previousSession() { activeSessionID = prev.id }
    }

    /// Create and start a new session for a server connection.
    func connect(to connection: ServerConnection) async throws -> TerminalSession {
        let authMethod: SSHAuthMethod

        switch connection.authMethod {
        case .publicKey:
            let account = "private-key-\(connection.id.uuidString)"
            guard let pemData = try? await keychain.load(account: account),
                  let pemString = String(data: pemData, encoding: .utf8) else {
                throw SSHTransportError.authenticationFailed
            }
            let parsedKey = try SSHKeyImporter.importKey(from: pemString)
            let nioKey = try Self.makeNIOSSHPrivateKey(from: parsedKey)
            authMethod = .publicKey(nioKey)

        case .password, .keyboardInteractive:
            var password = connection.password
            if password.isEmpty {
                let account = "password-\(connection.id.uuidString)"
                if let data = try? await keychain.load(account: account) {
                    password = String(data: data, encoding: .utf8) ?? ""
                }
            }
            authMethod = .password(password)
        }

        let config = SSHConnectionConfig(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            authMethod: authMethod
        )
        let moshOptions = moshBootstrapOptions(for: connection)

        let transport: any TerminalTransport

        switch connection.transport {
        case .ssh:
            transport = SSHTransport(config: config)
        case .mosh:
            transport = MoshTransport(config: config, bootstrapOptions: moshOptions)
        }

        let scrollbackLines = UserDefaults.standard.integer(forKey: "scrollbackLines")
        let transportType = connection.transport
        let transportFactory: @Sendable () -> any TerminalTransport = {
            switch transportType {
            case .ssh:
                return SSHTransport(config: config)
            case .mosh:
                return MoshTransport(config: config, bootstrapOptions: moshOptions)
            }
        }
        let session = TerminalSession(
            connectionName: connection.name.isEmpty ? connection.host : connection.name,
            transport: transport,
            transportFactory: transportFactory,
            startupCommand: connection.startupCommand,
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

    /// Probe all active sessions to detect dead connections.
    func checkAllConnections() async {
        for session in sessions {
            await session.checkConnection()
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

    /// Automatically resume all non-stale mosh sessions on app launch.
    /// Sessions that fail to reconnect (server unreachable) are cleaned up silently.
    /// Server timeout is 600s; we filter at 550s to give a safety margin.
    func autoResumeSessions() async {
        let all = await sessionStore.loadAll()
        let cutoff = Date().addingTimeInterval(-550)
        let fresh = all.filter { $0.savedAt > cutoff }
        let stale = all.filter { $0.savedAt <= cutoff }

        // Clean up stale sessions
        for s in stale {
            await sessionStore.remove(sessionID: s.sessionID)
        }

        // Resume each fresh session concurrently
        await withTaskGroup(of: Void.self) { group in
            for saved in fresh {
                group.addTask { @MainActor in
                    do {
                        _ = try await self.resume(saved)
                    } catch {
                        // Server unreachable or other failure — clean up silently.
                        // Session was already removed from store in resume().
                    }
                }
            }
        }
    }

    /// Resume a saved mosh session.
    func resume(_ savedState: MoshSessionState) async throws -> TerminalSession {
        let authMethod: SSHAuthMethod

        if savedState.authMethodType == .publicKey {
            let account = "private-key-\(savedState.connectionID)"
            if let pemData = try? await keychain.load(account: account),
               let pemString = String(data: pemData, encoding: .utf8),
               let parsedKey = try? SSHKeyImporter.importKey(from: pemString),
               let nioKey = try? Self.makeNIOSSHPrivateKey(from: parsedKey) {
                authMethod = .publicKey(nioKey)
            } else {
                throw SSHTransportError.connectionFailed(
                    "Private key no longer available in Keychain. Please re-enter your key in the connection editor."
                )
            }
        } else {
            var password = ""
            let account = "password-\(savedState.connectionID)"
            if let data = try? await keychain.load(account: account) {
                password = String(data: data, encoding: .utf8) ?? ""
            }
            authMethod = .password(password)
        }

        let config = SSHConnectionConfig(
            host: savedState.sshHost,
            port: savedState.sshPort,
            username: savedState.sshUsername,
            authMethod: authMethod
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

        // Remove from store (session is now active, not persisted)
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

    // MARK: - Key Conversion

    /// Convert a parsed SSH key into a NIOSSHPrivateKey for use with NIOSSH.
    private static func makeNIOSSHPrivateKey(from parsedKey: ParsedSSHKey) throws -> NIOSSHPrivateKey {
        switch parsedKey.keyType {
        case .ed25519:
            let privateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: parsedKey.privateKeyData
            )
            return NIOSSHPrivateKey(ed25519Key: privateKey)
        case .ecdsaP256:
            let privateKey = try P256.Signing.PrivateKey(
                rawRepresentation: parsedKey.privateKeyData
            )
            return NIOSSHPrivateKey(p256Key: privateKey)
        case .ecdsaP384:
            let privateKey = try P384.Signing.PrivateKey(
                rawRepresentation: parsedKey.privateKeyData
            )
            return NIOSSHPrivateKey(p384Key: privateKey)
        case .rsa:
            throw SSHTransportError.authenticationFailed
        }
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

    private func moshBootstrapOptions(for connection: ServerConnection) -> MoshBootstrapOptions {
        let bindFamily: MoshBindFamily = switch connection.moshBindFamily {
        case .automatic:
            .automatic
        case .ipv4:
            .ipv4
        case .ipv6:
            .ipv6
        }

        let ipResolution: MoshIPResolution = switch connection.moshIPResolution {
        case .default:
            .default
        case .local:
            .local
        case .remote:
            .remote
        }

        return MoshBootstrapOptions(
            serverPath: normalizedOptional(connection.moshServerPath),
            udpPortRange: normalizedOptional(connection.moshUDPPortRange),
            allocatePTY: !connection.moshCompatibilityMode,
            bindFamily: bindFamily,
            ipResolution: ipResolution
        )
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
