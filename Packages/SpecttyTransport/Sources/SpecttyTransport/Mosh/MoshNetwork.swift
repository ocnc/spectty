import Foundation
import Network

/// UDP transport layer for Mosh using Network.framework.
final class MoshNetwork: @unchecked Sendable {
    private var connection: NWConnection
    private let crypto: MoshCryptoSession
    private var sendSequence: UInt64 = 0
    private let direction: MoshDirection

    // Stored for connection replacement during roaming
    private let host: String
    private let port: Int

    /// Callback for received packets.
    var onReceive: ((MoshPacket) -> Void)?

    /// Called when the connection's path viability changes.
    /// `true` = viable (connected), `false` = non-viable (path lost).
    var onViabilityChanged: ((Bool) -> Void)?

    private var running = false
    private var replacing = false

    init(host: String, port: Int, crypto: MoshCryptoSession, direction: MoshDirection = .toServer) {
        self.host = host
        self.port = port
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port))
        self.connection = NWConnection(host: nwHost, port: nwPort, using: .udp)
        self.crypto = crypto
        self.direction = direction
    }

    /// Start the UDP connection and begin receiving.
    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            nonisolated(unsafe) var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed {
                        resumed = true
                        cont.resume()
                    }
                    self?.running = true
                    self?.startReceiving()
                case .failed(let error):
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: error)
                    }
                case .cancelled:
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: MoshError.connectionClosed)
                    }
                default:
                    break
                }
            }
            installPathHandlers(on: connection)
            connection.start(queue: .global(qos: .userInteractive))
        }
        running = true
    }

    /// Send a packet (encrypts and transmits as UDP datagram).
    func send(payload: Data, timestamp: UInt16, timestampReply: UInt16) {
        sendSequence += 1
        let packet = MoshPacket(
            sequenceNumber: sendSequence,
            direction: direction,
            timestamp: timestamp,
            timestampReply: timestampReply,
            payload: payload
        )
        let datagram = crypto.seal(packet: packet)
        connection.send(content: datagram, completion: .contentProcessed { _ in })
    }

    /// Stop the connection.
    func stop() {
        running = false
        connection.cancel()
    }

    /// Replace the underlying UDP connection (for network roaming).
    /// Creates a new NWConnection to the same host:port, installs handlers,
    /// and resumes receiving. Does NOT reset sendSequence — the server
    /// authenticates by crypto nonce, not source IP.
    func replaceConnection() {
        guard running, !replacing else { return }
        replacing = true

        // Cancel old connection (clears its handlers to prevent re-entrant calls)
        connection.viabilityUpdateHandler = nil
        connection.betterPathUpdateHandler = nil
        connection.cancel()

        // Create new connection to same endpoint
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port))
        let newConnection = NWConnection(host: nwHost, port: nwPort, using: .udp)

        newConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.replacing = false
                self?.startReceiving()
            case .failed:
                self?.replacing = false
                self?.onViabilityChanged?(false)
            default:
                break
            }
        }

        installPathHandlers(on: newConnection)
        self.connection = newConnection
        newConnection.start(queue: .global(qos: .userInteractive))
    }

    // MARK: - Path Handlers

    /// Install viability and better-path handlers on a connection.
    private func installPathHandlers(on conn: NWConnection) {
        conn.viabilityUpdateHandler = { [weak self] viable in
            guard let self else { return }
            if viable {
                self.onViabilityChanged?(true)
            } else {
                self.onViabilityChanged?(false)
                // Path became non-viable — proactively replace
                self.replaceConnection()
            }
        }

        conn.betterPathUpdateHandler = { [weak self] hasBetterPath in
            guard let self, hasBetterPath else { return }
            // A better path is available (e.g. WiFi came back while on cellular)
            self.replaceConnection()
        }
    }

    // MARK: - Receive loop

    private func startReceiving() {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                let incomingDirection: MoshDirection = (self.direction == .toServer) ? .toClient : .toServer
                if let packet = self.crypto.open(datagram: data, direction: incomingDirection) {
                    self.onReceive?(packet)
                }
            }

            if error == nil {
                self.startReceiving()
            }
        }
    }
}
