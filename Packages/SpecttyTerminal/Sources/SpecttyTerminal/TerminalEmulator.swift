import Foundation

/// Key event from the UI layer.
public struct KeyEvent: Sendable {
    public var keyCode: UInt32
    public var modifiers: KeyModifiers
    public var isKeyDown: Bool
    public var characters: String

    public init(keyCode: UInt32, modifiers: KeyModifiers, isKeyDown: Bool, characters: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isKeyDown = isKeyDown
        self.characters = characters
    }
}

/// Modifier key bitmask.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift   = KeyModifiers(rawValue: 1 << 0)
    public static let alt     = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let `super` = KeyModifiers(rawValue: 1 << 3)
}

/// Protocol for terminal emulators. Designed to be swappable —
/// backed by our Swift state machine + libghostty-vt parsers,
/// or by a full libghostty C API.
public protocol TerminalEmulator: AnyObject, Sendable {
    /// The current screen state (for rendering).
    var state: TerminalState { get }

    /// Number of lines in scrollback.
    var scrollbackCount: Int { get }

    /// Feed raw bytes from the transport into the terminal.
    func feed(_ data: Data)

    /// Resize the terminal grid.
    func resize(columns: Int, rows: Int)

    /// Encode a key event into bytes to send to the transport.
    func encodeKey(_ event: KeyEvent) -> Data

    /// Get a specific scrollback line.
    func scrollbackLine(at index: Int) -> TerminalLine?
}
