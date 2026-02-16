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
    private(set) var transport: any TerminalTransport
    private let transportFactory: (@Sendable () -> any TerminalTransport)?
    private let startupCommand: String?

    private(set) var transportState: TransportState = .disconnected
    private(set) var title: String = ""

    @ObservationIgnored
    nonisolated(unsafe) private var receiveTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var stateTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var autoReconnectTask: Task<Void, Never>?

    init(id: UUID = UUID(), connectionName: String, transport: any TerminalTransport, transportFactory: (@Sendable () -> any TerminalTransport)? = nil, startupCommand: String? = nil, columns: Int = 80, rows: Int = 24, scrollbackCapacity: Int = 10_000) {
        self.id = id
        self.connectionName = connectionName
        self.emulator = GhosttyTerminalEmulator(columns: columns, rows: rows, scrollbackCapacity: scrollbackCapacity)
        self.transport = transport
        self.transportFactory = transportFactory
        self.startupCommand = startupCommand

        // Wire terminal responses (DSR, DA) back through the transport.
        // Capture transport directly — avoids accessing @MainActor self
        // from a non-isolated closure, which would trigger unsafeForcedSync.
        let transport = self.transport
        self.emulator.onResponse = { data in
            Task { try? await transport.send(data) }
        }
    }

    /// Start the session: connect and begin piping data.
    func start() async throws {
        try await transport.connect()

        // Sync the actual terminal size now that the connection is live.
        // The view may have laid out to a different size during the connection handshake.
        let cols = emulator.state.columns
        let rows = emulator.state.rows
        try? await transport.resize(columns: cols, rows: rows)

        // Listen for transport state changes.
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.transport.state {
                if case .disconnected = state, self.transportFactory != nil {
                    self.attemptAutoReconnect()
                } else {
                    self.transportState = state
                }
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

        sendStartupCommand()
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
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        receiveTask?.cancel()
        stateTask?.cancel()
        Task {
            try? await transport.disconnect()
        }
    }

    /// Check if the connection is still alive.
    func checkConnection() async {
        await transport.checkConnection()
    }

    /// Tear down the current transport and reconnect with a fresh one.
    func reconnect() async throws {
        guard let transportFactory else { return }

        // Stop old transport
        receiveTask?.cancel()
        stateTask?.cancel()
        try? await transport.disconnect()

        // Create fresh transport
        let newTransport = transportFactory()
        self.transport = newTransport

        // Re-wire emulator response handler
        self.emulator.onResponse = { data in
            Task { try? await newTransport.send(data) }
        }

        // Connect and start streams (same as start())
        try await newTransport.connect()
        let cols = emulator.state.columns
        let rows = emulator.state.rows
        try? await newTransport.resize(columns: cols, rows: rows)

        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in newTransport.state {
                if case .disconnected = state, self.transportFactory != nil {
                    self.attemptAutoReconnect()
                } else {
                    self.transportState = state
                }
            }
        }

        receiveTask = Task { [weak self] in
            guard let self else { return }
            for await data in newTransport.incomingData {
                self.emulator.feed(data)
                let newTitle = self.emulator.state.activeScreen.title
                if !newTitle.isEmpty && newTitle != self.title {
                    self.title = newTitle
                }
            }
        }

        sendStartupCommand()
    }

    /// Manually retry connection after auto-reconnect has failed.
    func retryConnection() {
        attemptAutoReconnect()
    }

    private func attemptAutoReconnect() {
        guard autoReconnectTask == nil else { return }
        transportState = .reconnecting
        autoReconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try await self.reconnect()
            } catch {
                self.transportState = .failed(error)
            }
            self.autoReconnectTask = nil
        }
    }

    private func sendStartupCommand() {
        guard let cmd = startupCommand, !cmd.isEmpty else { return }
        let transport = self.transport
        Task {
            try? await transport.send(Data((cmd + "\n").utf8))
        }
    }

    deinit {
        autoReconnectTask?.cancel()
        receiveTask?.cancel()
        stateTask?.cancel()
    }
}
