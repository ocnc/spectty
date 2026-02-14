import Foundation

/// Stub implementation of the Mosh transport.
///
/// Mosh (Mobile Shell) uses a UDP-based protocol with the State
/// Synchronization Protocol (SSP) on top of AES-128-OCB3 encryption.
/// The initial key exchange is performed over SSH, after which the
/// connection switches to UDP for roaming and resilience.
public final class MoshTransport: TerminalTransport, @unchecked Sendable {
    public let state: AsyncStream<TransportState>
    public let incomingData: AsyncStream<Data>

    private let stateContinuation: AsyncStream<TransportState>.Continuation
    private let dataContinuation: AsyncStream<Data>.Continuation

    public init() {
        var sc: AsyncStream<TransportState>.Continuation!
        self.state = AsyncStream { sc = $0 }
        self.stateContinuation = sc

        var dc: AsyncStream<Data>.Continuation!
        self.incomingData = AsyncStream { dc = $0 }
        self.dataContinuation = dc
    }

    public func connect() async throws {
        // TODO: Implement Mosh connection (SSH key exchange, then UDP)
        throw MoshError.notImplemented
    }

    public func disconnect() async throws {
        // TODO: Implement Mosh disconnect
        throw MoshError.notImplemented
    }

    public func send(_ data: Data) async throws {
        // TODO: Implement sending data over Mosh SSP
        throw MoshError.notImplemented
    }

    public func resize(columns: Int, rows: Int) async throws {
        // TODO: Implement Mosh resize
        throw MoshError.notImplemented
    }
}

enum MoshError: Error, CustomStringConvertible {
    case notImplemented

    var description: String {
        switch self {
        case .notImplemented:
            return "Mosh transport is not yet implemented"
        }
    }
}
