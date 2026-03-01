import Foundation

/// Terminal emulator implementation using our Swift VT state machine.
/// Uses libghostty-vt for parsing assistance where available,
/// with a full Swift fallback.
public final class GhosttyTerminalEmulator: TerminalEmulator, @unchecked Sendable {
    public let state: TerminalState
    private let vtStateMachine: VTStateMachine
    private let keyEncoder = KeyEncoder()

    /// Called when the terminal needs to send a response back to the host.
    public var onResponse: ((Data) -> Void)? {
        get { vtStateMachine.onResponse }
        set { vtStateMachine.onResponse = newValue }
    }

    /// Called when remote sends clipboard data (OSC 52 set).
    public var onSetClipboard: ((String) -> Void)? {
        get { vtStateMachine.onSetClipboard }
        set { vtStateMachine.onSetClipboard = newValue }
    }

    /// Called when remote queries local clipboard (OSC 52 query).
    public var onGetClipboard: (() -> String?)? {
        get { vtStateMachine.onGetClipboard }
        set { vtStateMachine.onGetClipboard = newValue }
    }

    public init(columns: Int = 80, rows: Int = 24, scrollbackCapacity: Int = 10_000) {
        self.state = TerminalState(columns: columns, rows: rows, scrollbackCapacity: scrollbackCapacity)
        self.vtStateMachine = VTStateMachine(state: self.state)
    }

    public var scrollbackCount: Int {
        state.scrollback.count
    }

    public func feed(_ data: Data) {
        vtStateMachine.feed(data)
    }

    public func resize(columns: Int, rows: Int) {
        state.resize(columns: columns, rows: rows)
    }

    public func encodeKey(_ event: KeyEvent) -> Data {
        keyEncoder.encode(event, modes: state.modes)
    }

    public func scrollbackLine(at index: Int) -> TerminalLine? {
        state.scrollback.line(at: index)
    }
}
