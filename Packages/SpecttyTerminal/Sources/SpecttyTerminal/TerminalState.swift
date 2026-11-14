import Foundation

/// Cursor style for the terminal.
public enum CursorStyle: Sendable {
    case block
    case underline
    case bar
}

/// Cursor position and visibility.
public struct CursorState: Equatable, Sendable {
    public var row: Int = 0
    public var col: Int = 0
    public var visible: Bool = true
    public var style: CursorStyle = .block


}

/// Terminal mode flags.
public struct TerminalModes: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Application cursor keys (DECCKM).
    public static let applicationCursor = TerminalModes(rawValue: 1 << 0)
    /// Application keypad (DECKPAM).
    public static let applicationKeypad = TerminalModes(rawValue: 1 << 1)
    /// Auto-wrap mode (DECAWM).
    public static let autoWrap = TerminalModes(rawValue: 1 << 2)
    /// Origin mode (DECOM).
    public static let originMode = TerminalModes(rawValue: 1 << 3)
    /// Insert mode (IRM).
    public static let insertMode = TerminalModes(rawValue: 1 << 4)
    /// Line feed / new line mode (LNM).
    public static let lineFeedNewLine = TerminalModes(rawValue: 1 << 5)
    /// Bracketed paste mode.
    public static let bracketedPaste = TerminalModes(rawValue: 1 << 6)
    /// Focus events.
    public static let focusEvents = TerminalModes(rawValue: 1 << 7)
    /// Alternate screen buffer active.
    public static let alternateScreen = TerminalModes(rawValue: 1 << 8)
    /// Mouse tracking: button events.
    public static let mouseButton = TerminalModes(rawValue: 1 << 9)
    /// Mouse tracking: any events.
    public static let mouseAny = TerminalModes(rawValue: 1 << 10)
    /// Mouse tracking: SGR extended mode.
    public static let mouseSGR = TerminalModes(rawValue: 1 << 11)
    /// Kitty keyboard protocol is negotiated.
    public static let kittyKeyboard = TerminalModes(rawValue: 1 << 13)
    /// Cursor visible (DECTCEM).
    public static let cursorVisible = TerminalModes(rawValue: 1 << 12)
}

/// The complete state of a terminal screen (either primary or alternate).
public final class TerminalScreenState: @unchecked Sendable {
    public var columns: Int
    public var rows: Int
    public var lines: [TerminalLine]
    public var cursor: CursorState
    /// Window title set via OSC.
    public var title: String = ""

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        self.lines = (0..<rows).map { _ in TerminalLine(columns: columns) }
        self.cursor = CursorState()
    }

    /// Extract all visible text as a string, trimming trailing whitespace per line.
    public func text() -> String {
        var result = [String]()
        for line in lines {
            result.append(line.textContent())
        }
        // Trim trailing empty lines.
        while result.last?.isEmpty == true {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

}

/// The full terminal state including both screens and scrollback.
public final class TerminalState: @unchecked Sendable {
    public let primaryScreen: TerminalScreenState
    public let alternateScreen: TerminalScreenState
    public var scrollback: TerminalBuffer

    /// Terminal modes (shared across screens).
    public var modes: TerminalModes

    /// Which screen is currently active.
    public var activeScreen: TerminalScreenState

    public var columns: Int { activeScreen.columns }
    public var rows: Int { activeScreen.rows }

    public init(columns: Int, rows: Int, scrollbackCapacity: Int = 10_000) {
        self.primaryScreen = TerminalScreenState(columns: columns, rows: rows)
        self.alternateScreen = TerminalScreenState(columns: columns, rows: rows)
        self.scrollback = TerminalBuffer(capacity: scrollbackCapacity)
        self.modes = [.autoWrap, .cursorVisible]
        self.activeScreen = primaryScreen

    }
}

public extension TerminalCell {
    var isWideHead: Bool { attributes.contains(.wideChar) }
    var isWideTail: Bool { attributes.contains(.wideCharTail) }
}

public extension TerminalLine {
    mutating func normalizeWideCharacters() {
        guard !cells.isEmpty else { return }

        for index in cells.indices {
            let cell = cells[index]
            if cell.isWideTail {
                let hasHead = index > 0 && cells[index - 1].isWideHead
                if !hasHead {
                    cells[index] = .blank
                }
            }

            if cell.isWideHead {
                let hasTail = index + 1 < cells.count && cells[index + 1].isWideTail
                if !hasTail {
                    cells[index] = .blank
                }
            }
        }
    }

    func textContent() -> String {
        var text = ""
        var index = 0
        while index < cells.count {
            let cell = cells[index]
            if cell.isWideTail {
                index += 1
                continue
            }
            text.append(cell.character)
            index += cell.isWideHead ? 2 : 1
        }
        let lineText = text.replacingOccurrences(of: "\0", with: " ")
        return lineText.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }
}
