import Foundation

/// Mosh transport errors.
public enum MoshError: Error, LocalizedError {
    case invalidKey
    case bootstrapFailed(String)
    case connectionClosed
    case notConnected

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
        }
    }
}

/// Native Swift Mosh (Mobile Shell) transport.
///
/// Connects by: SSH exec → mosh-server → parse key+port → UDP/OCB3/SSP.
/// The SSP receiver emits `HostBytes` (raw terminal output) through the
/// `incomingData` stream, which feeds the Ghostty terminal emulator.
public final class MoshTransport: TerminalTransport, @unchecked Sendable {
    public let state: AsyncStream<TransportState>
    public let incomingData: AsyncStream<Data>

    private let config: SSHConnectionConfig
    private let stateContinuation: AsyncStream<TransportState>.Continuation
    private let dataContinuation: AsyncStream<Data>.Continuation

    nonisolated(unsafe) private var network: MoshNetwork?
    nonisolated(unsafe) private var ssp: MoshSSP?
    nonisolated(unsafe) private var sessionUDPPort: Int?

    public init(config: SSHConnectionConfig) {
        self.config = config

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
        stateContinuation.yield(.connecting)

        // Phase 1: SSH bootstrap — exec mosh-server to get UDP port + key
        // SSH is closed after bootstrap; mosh communicates entirely over UDP.
        let session: MoshSession
        do {
            session = try await MoshBootstrap.start(config: config)
        } catch {
            print("[Mosh] Bootstrap failed: \(error)")
            stateContinuation.yield(.failed(error))
            throw error
        }
        self.sessionUDPPort = session.udpPort

        // Phase 2: Set up crypto with the session key
        let crypto: MoshCryptoSession
        do {
            crypto = try MoshCryptoSession(base64Key: session.key)
        } catch {
            stateContinuation.yield(.failed(error))
            throw error
        }

        // Phase 3: UDP connection
        let net = MoshNetwork(host: session.host, port: session.udpPort, crypto: crypto)
        self.network = net

        do {
            try await net.start()
        } catch {
            stateContinuation.yield(.failed(error))
            throw error
        }
        // Phase 4: Start SSP
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
}
