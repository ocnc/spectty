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

    /// Saved cursor state for DECSC/DECRC.
    public struct SavedState: Sendable {
        public var row: Int
        public var col: Int
        public var attributes: CellAttributes
        public var fg: TerminalColor
        public var bg: TerminalColor
    }
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
    /// Cursor visible (DECTCEM).
    public static let cursorVisible = TerminalModes(rawValue: 1 << 12)
}

/// The complete state of a terminal screen (either primary or alternate).
public final class TerminalScreenState: @unchecked Sendable {
    public var columns: Int
    public var rows: Int
    public var lines: [TerminalLine]
    public var cursor: CursorState
    public var savedCursor: CursorState.SavedState?

    /// Current SGR attributes applied to new characters.
    public var currentAttributes: CellAttributes = []
    public var currentFG: TerminalColor = .default
    public var currentBG: TerminalColor = .default

    /// Scroll region (top and bottom, 0-indexed, inclusive).
    public var scrollTop: Int = 0
    public var scrollBottom: Int

    /// Tab stops.
    public var tabStops: Set<Int>

    /// Window title set via OSC.
    public var title: String = ""

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        self.lines = (0..<rows).map { _ in TerminalLine(columns: columns) }
        self.cursor = CursorState()
        self.scrollBottom = rows - 1
        // Default tab stops every 8 columns.
        self.tabStops = Set(stride(from: 8, to: columns, by: 8))
    }

    /// Extract all visible text as a string, trimming trailing whitespace per line.
    public func text() -> String {
        var result = [String]()
        for line in lines {
            let lineText = String(line.cells.map { $0.character })
                .replacingOccurrences(of: "\0", with: " ")
            result.append(lineText.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        // Trim trailing empty lines.
        while result.last?.isEmpty == true {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

    /// Reset the screen to blank.
    public func reset() {
        for i in 0..<rows {
            lines[i] = TerminalLine(columns: columns)
        }
        cursor = CursorState()
        savedCursor = nil
        currentAttributes = []
        currentFG = .default
        currentBG = .default
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Set(stride(from: 8, to: columns, by: 8))
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

    /// The 256-color palette (mutable for OSC color changes).
    public var colorPalette: [(UInt8, UInt8, UInt8)]

    public var columns: Int { activeScreen.columns }
    public var rows: Int { activeScreen.rows }

    public init(columns: Int, rows: Int, scrollbackCapacity: Int = 10_000) {
        self.primaryScreen = TerminalScreenState(columns: columns, rows: rows)
        self.alternateScreen = TerminalScreenState(columns: columns, rows: rows)
        self.scrollback = TerminalBuffer(capacity: scrollbackCapacity)
        self.modes = [.autoWrap, .cursorVisible]
        self.activeScreen = primaryScreen

        // Initialize color palette from the default ANSI colors.
        var palette = [(UInt8, UInt8, UInt8)]()
        palette.reserveCapacity(256)
        for color in TerminalColor.palette {
            switch color {
            case .rgb(let r, let g, let b):
                palette.append((r, g, b))
            default:
                palette.append((0, 0, 0))
            }
        }
        self.colorPalette = palette
    }

    /// Resize the terminal. Reflows the primary screen.
    public func resize(columns: Int, rows: Int) {
        resizeScreen(primaryScreen, columns: columns, rows: rows)
        resizeScreen(alternateScreen, columns: columns, rows: rows)
    }

    private func resizeScreen(_ screen: TerminalScreenState, columns: Int, rows: Int) {
        let oldRows = screen.rows
        screen.columns = columns
        screen.rows = rows

        // Resize existing lines.
        for i in 0..<screen.lines.count {
            screen.lines[i].resize(columns: columns)
        }

        // Add or remove lines as needed.
        if rows > oldRows {
            let needed = rows - oldRows
            if screen === primaryScreen {
                // Pull lines back from scrollback to restore content.
                var recovered = [TerminalLine]()
                for _ in 0..<needed {
                    if var line = scrollback.popLast() {
                        line.resize(columns: columns)
                        recovered.insert(line, at: 0)
                    } else {
                        break
                    }
                }
                screen.lines.insert(contentsOf: recovered, at: 0)
                screen.cursor.row += recovered.count
                // Fill any remaining with blank lines.
                let remaining = needed - recovered.count
                for _ in 0..<remaining {
                    screen.lines.append(TerminalLine(columns: columns))
                }
            } else {
                for _ in oldRows..<rows {
                    screen.lines.append(TerminalLine(columns: columns))
                }
            }
        } else if rows < oldRows {
            // Remove lines from the top, pushing them to scrollback if primary.
            let excess = oldRows - rows
            if screen === primaryScreen {
                for i in 0..<excess {
                    scrollback.push(screen.lines[i])
                }
            }
            screen.lines.removeFirst(excess)
        }

        // Clamp cursor.
        screen.cursor.row = min(screen.cursor.row, rows - 1)
        screen.cursor.col = min(screen.cursor.col, columns - 1)

        // Adjust scroll region.
        screen.scrollTop = 0
        screen.scrollBottom = rows - 1

        // Recalculate tab stops.
        screen.tabStops = Set(stride(from: 8, to: columns, by: 8))
    }
}
