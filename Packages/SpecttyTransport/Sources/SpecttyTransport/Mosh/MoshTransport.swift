import Foundation

/// Mosh transport errors.
public enum MoshError: Error, LocalizedError {
    case invalidKey
    case bootstrapFailed(String)
    case connectionClosed
    case notConnected
    case serverUnreachable
    case symmetricNAT

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Invalid Mosh session key"
        case .bootstrapFailed(let detail):
            return "Mosh bootstrap failed: \(detail)"
        case .connectionClosed:
            return "Mosh connection was closed"
        case .notConnected:
            return "Mosh transport is not connected"
        case .serverUnreachable:
            return "Mosh server is unreachable"
        case .symmetricNAT:
            return "Symmetric NAT detected — UDP connections may be unreliable. Consider using a VPN."
        }
    }
}

/// Native Swift Mosh (Mobile Shell) transport.
///
/// Connects by: SSH exec → mosh-server → parse key+port → UDP/OCB3/SSP.
/// The SSP receiver emits `HostBytes` (raw terminal output) through the
/// `incomingData` stream, which feeds the Ghostty terminal emulator.
public final class MoshTransport: ResumableTransport, @unchecked Sendable {
    public let state: AsyncStream<TransportState>
    public let incomingData: AsyncStream<Data>

    private let config: SSHConnectionConfig
    private let stateContinuation: AsyncStream<TransportState>.Continuation
    private let dataContinuation: AsyncStream<Data>.Continuation

    nonisolated(unsafe) private var network: MoshNetwork?
    nonisolated(unsafe) private var ssp: MoshSSP?
    nonisolated(unsafe) private var sessionUDPPort: Int?
    nonisolated(unsafe) private var sessionKey: String?
    nonisolated(unsafe) private var sessionHost: String?

    /// Saved state for session resumption (set via `init(resuming:config:)`).
    nonisolated(unsafe) private var savedState: MoshSessionState?

    /// NAT type detected during pre-flight STUN check. Available after `connect()`.
    public nonisolated(unsafe) private(set) var detectedNATType: STUNClient.NATType?

    public init(config: SSHConnectionConfig) {
        self.config = config

        var sc: AsyncStream<TransportState>.Continuation!
        self.state = AsyncStream { sc = $0 }
        self.stateContinuation = sc

        var dc: AsyncStream<Data>.Continuation!
        self.incomingData = AsyncStream { dc = $0 }
        self.dataContinuation = dc
    }

    /// Create a transport for resuming a saved session (skips SSH bootstrap).
    public init(resuming savedState: MoshSessionState, config: SSHConnectionConfig) {
        self.config = config
        self.savedState = savedState

        var sc: AsyncStream<TransportState>.Continuation!
        self.state = AsyncStream { sc = $0 }
        self.stateContinuation = sc

        var dc: AsyncStream<Data>.Continuation!
        self.incomingData = AsyncStream { dc = $0 }
        self.dataContinuation = dc
    }

    deinit {
        ssp?.stop()
        network?.stop()
        stateContinuation.finish()
        dataContinuation.finish()
    }

    // MARK: - TerminalTransport

    public func connect() async throws {
        // If we have saved state, do a resume instead of fresh bootstrap
        if let saved = savedState {
            savedState = nil
            try await reconnect(from: saved)
            return
        }

        stateContinuation.yield(.connecting)

        // Pre-flight: detect NAT type. Symmetric NAT can cause UDP issues.
        // Run concurrently with a short timeout — don't delay the connection.
        let natType = await withTaskGroup(of: STUNClient.NATType.self) { group in
            group.addTask { await STUNClient.detectNATType() }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return STUNClient.NATType.unknown
            }
            let result = await group.next() ?? .unknown
            group.cancelAll()
            return result
        }
        self.detectedNATType = natType
        if natType == .symmetricNAT {
            // Symmetric NAT detected — UDP may be unreliable
        }

        // SSH bootstrap — exec mosh-server to get UDP port + key.
        // SSH is closed after bootstrap; mosh communicates entirely over UDP.
        let session: MoshSession
        do {
            session = try await MoshBootstrap.start(config: config)
        } catch {
            stateContinuation.yield(.failed(error))
            throw error
        }
        self.sessionUDPPort = session.udpPort
        self.sessionKey = session.key
        self.sessionHost = session.host

        // Set up crypto with the session key
        let crypto: MoshCryptoSession
        do {
            crypto = try MoshCryptoSession(base64Key: session.key)
        } catch {
            stateContinuation.yield(.failed(error))
            throw error
        }

        // UDP connection
        let net = MoshNetwork(host: session.host, port: session.udpPort, crypto: crypto)
        self.network = net

        do {
            try await net.start()
        } catch {
            stateContinuation.yield(.failed(error))
            throw error
        }

        // Install roaming handlers
        installRoamingHandlers(on: net)

        // Start SSP
        let ssp = MoshSSP(network: net)
        self.ssp = ssp

        ssp.onHostBytes = { [weak self] data in
            self?.dataContinuation.yield(data)
        }

        ssp.start()

        stateContinuation.yield(.connected)
    }

    public func disconnect() async throws {
        ssp?.stop()
        ssp = nil

        network?.stop()
        network = nil

        // Kill the remote mosh-server via SSH (best-effort).
        // Falls back to MOSH_SERVER_NETWORK_TMOUT auto-cleanup.
        if let port = sessionUDPPort {
            MoshBootstrap.killServer(config: config, udpPort: port)
            sessionUDPPort = nil
        }

        stateContinuation.yield(.disconnected)
        dataContinuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard let ssp else {
            throw MoshError.notConnected
        }
        ssp.queueKeystrokes(data)
    }

    public func resize(columns: Int, rows: Int) async throws {
        guard let ssp else {
            return // Not connected yet; will be set after connect
        }
        ssp.queueResize(columns: columns, rows: rows)
    }

    // MARK: - Session State Export

    /// Export current session state for persistence. Returns nil if not connected.
    public func exportSessionState(
        sessionID: String,
        connectionID: String,
        connectionName: String
    ) -> MoshSessionState? {
        guard let ssp, let host = sessionHost, let port = sessionUDPPort, let key = sessionKey else {
            return nil
        }
        let sspState = ssp.exportState()
        let authType: SSHAuthMethodType? = switch config.authMethod {
        case .password: nil
        case .publicKey: .publicKey
        }
        return MoshSessionState(
            sessionID: sessionID,
            connectionID: connectionID,
            connectionName: connectionName,
            host: host,
            udpPort: port,
            key: key,
            senderCurrentNum: sspState.senderCurrentNum,
            senderAckedNum: sspState.senderAckedNum,
            receiverCurrentNum: sspState.receiverCurrentNum,
            sshHost: config.host,
            sshPort: config.port,
            sshUsername: config.username,
            authMethodType: authType,
            savedAt: Date()
        )
    }

    // MARK: - Reconnect (Session Resumption)

    /// Reconnect to a saved mosh session, skipping SSH bootstrap entirely.
    private func reconnect(from saved: MoshSessionState) async throws {
        stateContinuation.yield(.reconnecting)

        // Recreate crypto from saved key
        let crypto: MoshCryptoSession
        do {
            crypto = try MoshCryptoSession(base64Key: saved.key)
        } catch {
            stateContinuation.yield(.failed(error))
            throw error
        }

        self.sessionKey = saved.key
        self.sessionHost = saved.host
        self.sessionUDPPort = saved.udpPort

        // Create UDP connection to saved host:port
        let net = MoshNetwork(host: saved.host, port: saved.udpPort, crypto: crypto)
        self.network = net

        do {
            try await net.start()
        } catch {
            stateContinuation.yield(.failed(error))
            throw error
        }

        // Install roaming handlers
        installRoamingHandlers(on: net)

        // Create SSP and import saved state
        let ssp = MoshSSP(network: net)
        self.ssp = ssp

        ssp.importState(MoshSSP.SSPState(
            senderCurrentNum: saved.senderCurrentNum,
            senderAckedNum: saved.senderAckedNum,
            receiverCurrentNum: saved.receiverCurrentNum
        ))

        ssp.onHostBytes = { [weak self] data in
            self?.dataContinuation.yield(data)
        }

        ssp.start()

        // Wait for a server packet within timeout to confirm the session is alive.
        // Poll the SSP's hasReceivedServerPacket flag rather than consuming incomingData
        // (which is already consumed by TerminalSession).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if ssp.hasReceivedServerPacket {
                stateContinuation.yield(.connected)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        // Server didn't respond — clean up
        ssp.stop()
        self.ssp = nil
        net.stop()
        self.network = nil
        let error = MoshError.serverUnreachable
        stateContinuation.yield(.failed(error))
        throw error
    }

    // MARK: - Roaming

    private func installRoamingHandlers(on net: MoshNetwork) {
        net.onViabilityChanged = { [weak self] viable in
            guard let self else { return }
            if viable {
                self.stateContinuation.yield(.connected)
                self.ssp?.forceRetransmit()
            } else {
                self.stateContinuation.yield(.reconnecting)
            }
        }
    }
}
