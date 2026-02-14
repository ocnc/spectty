import Foundation
import SpecttyTerminal
import SpecttyTransport

/// An active terminal session wiring together a transport and emulator.
@Observable
@MainActor
final class TerminalSession: Identifiable {
    let id: UUID
    var connectionName: String
    let emulator: GhosttyTerminalEmulator
    let transport: any TerminalTransport

    private(set) var transportState: TransportState = .disconnected
    private(set) var title: String = ""

    nonisolated(unsafe) private var receiveTask: Task<Void, Never>?
    nonisolated(unsafe) private var stateTask: Task<Void, Never>?

    init(id: UUID = UUID(), connectionName: String, transport: any TerminalTransport, columns: Int = 80, rows: Int = 24, scrollbackCapacity: Int = 10_000) {
        self.id = id
        self.connectionName = connectionName
        self.emulator = GhosttyTerminalEmulator(columns: columns, rows: rows, scrollbackCapacity: scrollbackCapacity)
        self.transport = transport
    }

    /// Start the session: connect and begin piping data.
    func start() async throws {
        try await transport.connect()

        // Listen for transport state changes.
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.transport.state {
                self.transportState = state
            }
        }

        // Listen for incoming data and feed to emulator.
        receiveTask = Task { [weak self] in
            guard let self else { return }
            for await data in self.transport.incomingData {
                self.emulator.feed(data)
                // Update title from terminal state.
                let newTitle = self.emulator.state.activeScreen.title
                if !newTitle.isEmpty && newTitle != self.title {
                    self.title = newTitle
                }
            }
        }
    }

    /// Send encoded key data to the transport.
    func sendKey(_ event: KeyEvent) {
        let data = emulator.encodeKey(event)
        guard !data.isEmpty else { return }
        Task {
            try? await transport.send(data)
        }
    }

    /// Send raw data to the transport (for paste, mouse events, etc.).
    func sendData(_ data: Data) {
        Task {
            try? await transport.send(data)
        }
    }

    /// Resize the terminal and notify the transport.
    func resize(columns: Int, rows: Int) {
        emulator.resize(columns: columns, rows: rows)
        Task {
            try? await transport.resize(columns: columns, rows: rows)
        }
    }

    /// Disconnect and clean up.
    func stop() {
        receiveTask?.cancel()
        stateTask?.cancel()
        Task {
            try? await transport.disconnect()
        }
    }

    deinit {
        receiveTask?.cancel()
        stateTask?.cancel()
    }
}
