import Foundation

/// Represents the current state of a terminal transport connection.
public enum TransportState: Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(Error)
}

extension TransportState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting"
        case .failed(let error): return "failed(\(error))"
        }
    }
}

/// Protocol for terminal transport layers (SSH, Mosh, etc.).
///
/// Conformers are responsible for establishing and managing a connection
/// to a remote host, piping data between the local terminal emulator
/// and the remote shell.
public protocol TerminalTransport: AnyObject, Sendable {
    /// An asynchronous stream of transport state changes.
    var state: AsyncStream<TransportState> { get }

    /// An asynchronous stream of incoming data from the remote host.
    var incomingData: AsyncStream<Data> { get }

    /// Establish the connection to the remote host.
    func connect() async throws

    /// Tear down the connection.
    func disconnect() async throws

    /// Send data to the remote host.
    func send(_ data: Data) async throws

    /// Notify the remote host that the terminal has been resized.
    func resize(columns: Int, rows: Int) async throws
}

/// Capability protocol for transports that support session persistence
/// and resumption across app restarts (e.g. Mosh).
public protocol ResumableTransport: TerminalTransport {
    /// Export the current session state for persistence. Returns nil if not connected.
    func exportSessionState(
        sessionID: String,
        connectionID: String,
        connectionName: String
    ) -> MoshSessionState?
}
