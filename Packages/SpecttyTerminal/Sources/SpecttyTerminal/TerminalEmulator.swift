import Foundation

/// Key event from the UI layer.
public struct KeyEvent: Sendable {
    public var keyCode: UInt32
    public var modifiers: KeyModifiers
    public var isKeyDown: Bool
    public var characters: String
    /// Layout character before modifiers, supplied by hardware keyboards.
    public var unshiftedCharacters: String?

    public init(keyCode: UInt32, modifiers: KeyModifiers, isKeyDown: Bool, characters: String, unshiftedCharacters: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isKeyDown = isKeyDown
        self.characters = characters
        self.unshiftedCharacters = unshiftedCharacters
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

/// The terminal interface shared by sessions, input, and rendering.
public protocol TerminalEmulator: AnyObject, Sendable {
    /// The current screen state (for rendering).
    var state: TerminalState { get }

    /// Number of lines in scrollback.
    var scrollbackCount: Int { get }

    /// Called after the visible terminal content changes and a redraw is needed.
    var onDisplayChange: (@Sendable () -> Void)? { get set }

    var onBell: (@Sendable () -> Void)? { get set }
    /// Remaining synchronized-output hold, bounded so a broken program cannot freeze rendering.
    func renderDelay(now: TimeInterval) -> TimeInterval
    func setFocused(_ focused: Bool)
    func setDefaultCursorStyle(_ style: CursorStyle)

    /// Feed raw bytes from the transport into the terminal.
    func feed(_ data: Data)

    /// Resize the terminal grid.
    func resize(columns: Int, rows: Int)

    /// Encode a key event into bytes to send to the transport.
    func encodeKey(_ event: KeyEvent) -> Data

    /// Resolve native image placements in physical pixels and advance animations.
    func graphicsFrame(scrollOffset: Int, cellSize: CGSize, now: TimeInterval) -> TerminalGraphicsFrame

    /// Get a specific scrollback line.
    func scrollbackLine(at index: Int) -> TerminalLine?
}
