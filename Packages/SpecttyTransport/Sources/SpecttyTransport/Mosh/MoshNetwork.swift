import Foundation
import Network

/// UDP transport layer for Mosh using Network.framework.
final class MoshNetwork: @unchecked Sendable {
    private let connection: NWConnection
    private let crypto: MoshCryptoSession
    private var sendSequence: UInt64 = 0
    private let direction: MoshDirection

    /// Callback for received packets.
    var onReceive: ((MoshPacket) -> Void)?

    private var running = false

    init(host: String, port: Int, crypto: MoshCryptoSession, direction: MoshDirection = .toServer) {
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
        connection.send(content: datagram, completion: .contentProcessed { error in
            if let error {
                print("[Mosh] UDP send error: \(error)")
            }
        })
    }

    /// Stop the connection.
    func stop() {
        running = false
        connection.cancel()
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
