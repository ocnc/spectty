import Foundation

/// VT100/xterm escape sequence parser and state machine.
/// Parses raw byte streams and applies mutations to TerminalState.
///
/// This is a custom parser implementing the standard VT state machine
/// (per https://vt100.net/emu/dec_ansi_parser). In the future, the
/// parsing can be delegated to libghostty-vt's C API.
public final class VTStateMachine: @unchecked Sendable {
    private let terminalState: TerminalState

    private enum ParserState {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case oscString
        case dcsEntry
        case dcsParam
        case dcsPassthrough
    }

    private var parserState: ParserState = .ground
    private var params: [UInt16] = []
    private var currentParam: UInt16 = 0
    private var hasParam: Bool = false
    private var intermediateChar: Character = "\0"
    private var oscPayload: [UInt8] = []
    private var utf8Buffer: [UInt8] = []

    /// Called when the terminal needs to send a response back to the host
    /// (e.g., cursor position report, device attributes).
    public var onResponse: ((Data) -> Void)?

    public init(state: TerminalState) {
        self.terminalState = state
    }

    // MARK: - Public API

    /// Feed raw bytes from the transport.
    public func feed(_ data: Data) {
        for byte in data {
            feedByte(byte)
        }
    }

    // MARK: - Byte Processing

    private func feedByte(_ byte: UInt8) {
        // Handle UTF-8 multi-byte sequences in ground state.
        if parserState == .ground && !utf8Buffer.isEmpty {
            utf8Buffer.append(byte)
            if let scalar = decodeUTF8(utf8Buffer) {
                let char = Character(scalar)
                printChar(char)
                utf8Buffer.removeAll()
            } else if utf8Buffer.count >= 4 {
                // Invalid sequence, discard.
                utf8Buffer.removeAll()
            }
            return
        }

        // C0 controls that work in any state.
        switch byte {
        case 0x18, 0x1A: // CAN, SUB
            parserState = .ground
            return
        case 0x1B: // ESC
            parserState = .escape
            intermediateChar = "\0"
            return
        default:
            break
        }

        switch parserState {
        case .ground:
            handleGround(byte)
        case .escape:
            handleEscape(byte)
        case .escapeIntermediate:
            handleEscapeIntermediate(byte)
        case .csiEntry:
            handleCSIEntry(byte)
        case .csiParam:
            handleCSIParam(byte)
        case .csiIntermediate:
            handleCSIIntermediate(byte)
        case .oscString:
            handleOSCString(byte)
        case .dcsEntry:
            handleDCSEntry(byte)
        case .dcsParam:
            handleDCSParam(byte)
        case .dcsPassthrough:
            handleDCSPassthrough(byte)
        }
    }

    // MARK: - Ground State

    private func handleGround(_ byte: UInt8) {
        switch byte {
        case 0x00...0x06, 0x0E...0x1A, 0x1C...0x1F:
            executeC0(byte)
        case 0x07:
            // BEL — ignore for now
            break
        case 0x08:
            executeC0(byte)
        case 0x09:
            executeC0(byte)
        case 0x0A...0x0C:
            executeC0(byte)
        case 0x0D:
            executeC0(byte)
        case 0x20...0x7E:
            printChar(Character(UnicodeScalar(byte)))
        case 0x7F:
            break // DEL — ignore
        case 0xC0...0xDF:
            // Start of 2-byte UTF-8
            utf8Buffer = [byte]
        case 0xE0...0xEF:
            // Start of 3-byte UTF-8
            utf8Buffer = [byte]
        case 0xF0...0xF7:
            // Start of 4-byte UTF-8
            utf8Buffer = [byte]
        default:
            // Invalid UTF-8 lead byte or continuation byte, ignore.
            break
        }
    }

    // MARK: - Escape Sequences

    private func handleEscape(_ byte: UInt8) {
        switch byte {
        case 0x5B: // '['
            parserState = .csiEntry
            params.removeAll()
            currentParam = 0
            hasParam = false
            intermediateChar = "\0"
        case 0x5D: // ']'
            parserState = .oscString
            oscPayload.removeAll()
        case 0x50: // 'P' — DCS
            parserState = .dcsEntry
            params.removeAll()
            currentParam = 0
            hasParam = false
        case 0x20...0x2F: // Intermediate
            intermediateChar = Character(UnicodeScalar(byte))
            parserState = .escapeIntermediate
        case 0x37: // '7' — DECSC
            saveCursor()
            parserState = .ground
        case 0x38: // '8' — DECRC
            restoreCursor()
            parserState = .ground
        case 0x44: // 'D' — IND (Index, scroll down)
            index()
            parserState = .ground
        case 0x45: // 'E' — NEL (Next Line)
            screen.cursor.col = 0
            index()
            parserState = .ground
        case 0x48: // 'H' — HTS (Horizontal Tab Set)
            screen.tabStops.insert(screen.cursor.col)
            parserState = .ground
        case 0x4D: // 'M' — RI (Reverse Index)
            reverseIndex()
            parserState = .ground
        case 0x63: // 'c' — RIS (Full Reset)
            fullReset()
            parserState = .ground
        case 0x3D: // '=' — DECKPAM
            terminalState.modes.insert(.applicationKeypad)
            parserState = .ground
        case 0x3E: // '>' — DECKPNM
            terminalState.modes.remove(.applicationKeypad)
            parserState = .ground
        default:
            parserState = .ground
        }
    }

    private func handleEscapeIntermediate(_ byte: UInt8) {
        switch byte {
        case 0x20...0x2F:
            intermediateChar = Character(UnicodeScalar(byte))
        case 0x30...0x7E:
            // Dispatch escape sequence with intermediate.
            parserState = .ground
        default:
            parserState = .ground
        }
    }

    // MARK: - CSI Sequences

    private func handleCSIEntry(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39: // Digit
            currentParam = UInt16(byte - 0x30)
            hasParam = true
            parserState = .csiParam
        case 0x3B: // ';'
            params.append(0)
            parserState = .csiParam
        case 0x3C...0x3F: // '<', '=', '>', '?'
            intermediateChar = Character(UnicodeScalar(byte))
            parserState = .csiParam
        case 0x20...0x2F: // Intermediate
            parserState = .csiIntermediate
        case 0x40...0x7E: // Final
            dispatchCSI(final: byte)
            parserState = .ground
        default:
            parserState = .ground
        }
    }

    private func handleCSIParam(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39: // Digit
            currentParam = currentParam &* 10 &+ UInt16(byte - 0x30)
            hasParam = true
        case 0x3B: // ';'
            params.append(hasParam ? currentParam : 0)
            currentParam = 0
            hasParam = false
        case 0x20...0x2F: // Intermediate
            if hasParam {
                params.append(currentParam)
            }
            parserState = .csiIntermediate
        case 0x3C...0x3F: // Private marker (could appear after first param in some sequences)
            break
        case 0x40...0x7E: // Final
            if hasParam {
                params.append(currentParam)
            }
            dispatchCSI(final: byte)
            parserState = .ground
        default:
            parserState = .ground
        }
    }

    private func handleCSIIntermediate(_ byte: UInt8) {
        switch byte {
        case 0x20...0x2F:
            break // Collect intermediate
        case 0x40...0x7E:
            // Dispatch with intermediate — most are unhandled.
            parserState = .ground
        default:
            parserState = .ground
        }
    }

    // MARK: - OSC Sequences

    private func handleOSCString(_ byte: UInt8) {
        switch byte {
        case 0x07: // BEL terminates OSC
            dispatchOSC()
            parserState = .ground
        case 0x9C: // ST (8-bit)
            dispatchOSC()
            parserState = .ground
        case 0x1B:
            // Could be ESC \ (ST), peek ahead would be nice but we'll
            // handle it by checking for '\' in the next byte.
            dispatchOSC()
            parserState = .escape
        default:
            oscPayload.append(byte)
        }
    }

    // MARK: - DCS Sequences

    private func handleDCSEntry(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39:
            currentParam = UInt16(byte - 0x30)
            hasParam = true
            parserState = .dcsParam
        case 0x40...0x7E:
            parserState = .dcsPassthrough
        default:
            parserState = .dcsPassthrough
        }
    }

    private func handleDCSParam(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39:
            currentParam = currentParam &* 10 &+ UInt16(byte - 0x30)
        case 0x3B:
            params.append(hasParam ? currentParam : 0)
            currentParam = 0
            hasParam = false
        case 0x40...0x7E:
            if hasParam { params.append(currentParam) }
            parserState = .dcsPassthrough
        default:
            parserState = .dcsPassthrough
        }
    }

    private func handleDCSPassthrough(_ byte: UInt8) {
        switch byte {
        case 0x9C: // ST
            parserState = .ground
        case 0x1B:
            parserState = .escape
        default:
            break // Accumulate or ignore
        }
    }

    // MARK: - Helpers

    private var screen: TerminalScreenState {
        terminalState.activeScreen
    }

    private func param(_ index: Int, default defaultValue: UInt16 = 0) -> Int {
        if index < params.count {
            return Int(params[index])
        }
        return Int(defaultValue)
    }

    // MARK: - C0 Control Characters

    private func executeC0(_ byte: UInt8) {
        switch byte {
        case 0x07: // BEL
            break
        case 0x08: // BS (Backspace)
            if screen.cursor.col > 0 {
                screen.cursor.col -= 1
            }
        case 0x09: // HT (Tab)
            let nextTab = screen.tabStops.sorted().first(where: { $0 > screen.cursor.col })
            screen.cursor.col = nextTab ?? (screen.columns - 1)
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            lineFeed()
        case 0x0D: // CR
            screen.cursor.col = 0
        case 0x0E: // SO (Shift Out)
            break // G1 character set — not implemented
        case 0x0F: // SI (Shift In)
            break // G0 character set — not implemented
        default:
            break
        }
    }

    // MARK: - Printing

    private func printChar(_ char: Character) {
        let s = screen

        // Auto-wrap: if we're past the right margin, wrap to next line.
        if s.cursor.col >= s.columns {
            if terminalState.modes.contains(.autoWrap) {
                s.cursor.col = 0
                lineFeed()
            } else {
                s.cursor.col = s.columns - 1
            }
        }

        // Write the cell.
        let row = s.cursor.row
        let col = s.cursor.col
        if row >= 0 && row < s.rows && col >= 0 && col < s.columns {
            s.lines[row].cells[col] = TerminalCell(
                character: char,
                fg: s.currentFG,
                bg: s.currentBG,
                attributes: s.currentAttributes
            )
            s.lines[row].isDirty = true
        }

        s.cursor.col += 1
    }

    // MARK: - Line Operations

    private func lineFeed() {
        let s = screen
        if s.cursor.row == s.scrollBottom {
            scrollUp()
        } else if s.cursor.row < s.rows - 1 {
            s.cursor.row += 1
        }
    }

    private func scrollUp(count: Int = 1) {
        let s = screen
        for _ in 0..<count {
            // Push the top line into scrollback if this is the primary screen.
            if terminalState.activeScreen === terminalState.primaryScreen && s.scrollTop == 0 {
                terminalState.scrollback.push(s.lines[s.scrollTop])
            }
            // Shift lines up within the scroll region.
            for row in s.scrollTop..<s.scrollBottom {
                s.lines[row] = s.lines[row + 1]
                s.lines[row].isDirty = true
            }
            s.lines[s.scrollBottom] = TerminalLine(columns: s.columns)
            s.lines[s.scrollBottom].isDirty = true
        }
    }

    private func scrollDown(count: Int = 1) {
        let s = screen
        for _ in 0..<count {
            for row in stride(from: s.scrollBottom, through: s.scrollTop + 1, by: -1) {
                s.lines[row] = s.lines[row - 1]
                s.lines[row].isDirty = true
            }
            s.lines[s.scrollTop] = TerminalLine(columns: s.columns)
            s.lines[s.scrollTop].isDirty = true
        }
    }

    private func index() {
        lineFeed()
    }

    private func reverseIndex() {
        let s = screen
        if s.cursor.row == s.scrollTop {
            scrollDown()
        } else if s.cursor.row > 0 {
            s.cursor.row -= 1
        }
    }

    // MARK: - Cursor Save/Restore

    private func saveCursor() {
        let s = screen
        s.savedCursor = CursorState.SavedState(
            row: s.cursor.row,
            col: s.cursor.col,
            attributes: s.currentAttributes,
            fg: s.currentFG,
            bg: s.currentBG
        )
    }

    private func restoreCursor() {
        let s = screen
        if let saved = s.savedCursor {
            s.cursor.row = min(saved.row, s.rows - 1)
            s.cursor.col = min(saved.col, s.columns - 1)
            s.currentAttributes = saved.attributes
            s.currentFG = saved.fg
            s.currentBG = saved.bg
        }
    }

    // MARK: - Full Reset

    private func fullReset() {
        terminalState.primaryScreen.reset()
        terminalState.alternateScreen.reset()
        terminalState.activeScreen = terminalState.primaryScreen
        terminalState.modes = [.autoWrap, .cursorVisible]
        terminalState.scrollback.clear()
    }

    // MARK: - CSI Dispatch

    private func dispatchCSI(final: UInt8) {
        let ch = Character(UnicodeScalar(final))

        // Private mode sequences (CSI ? ...)
        if intermediateChar == "?" {
            dispatchPrivateMode(ch)
            return
        }

        switch ch {
        case "A": // CUU — Cursor Up
            let n = max(param(0, default: 1), 1)
            screen.cursor.row = max(screen.cursor.row - n, screen.scrollTop)

        case "B": // CUD — Cursor Down
            let n = max(param(0, default: 1), 1)
            screen.cursor.row = min(screen.cursor.row + n, screen.scrollBottom)

        case "C": // CUF — Cursor Forward
            let n = max(param(0, default: 1), 1)
            screen.cursor.col = min(screen.cursor.col + n, screen.columns - 1)

        case "D": // CUB — Cursor Back
            let n = max(param(0, default: 1), 1)
            screen.cursor.col = max(screen.cursor.col - n, 0)

        case "E": // CNL — Cursor Next Line
            let n = max(param(0, default: 1), 1)
            screen.cursor.row = min(screen.cursor.row + n, screen.scrollBottom)
            screen.cursor.col = 0

        case "F": // CPL — Cursor Previous Line
            let n = max(param(0, default: 1), 1)
            screen.cursor.row = max(screen.cursor.row - n, screen.scrollTop)
            screen.cursor.col = 0

        case "G": // CHA — Cursor Horizontal Absolute
            let col = max(param(0, default: 1), 1) - 1
            screen.cursor.col = min(col, screen.columns - 1)

        case "H", "f": // CUP — Cursor Position
            let row = max(param(0, default: 1), 1) - 1
            let col = max(param(1, default: 1), 1) - 1
            screen.cursor.row = min(row, screen.rows - 1)
            screen.cursor.col = min(col, screen.columns - 1)

        case "J": // ED — Erase in Display
            eraseInDisplay(param(0, default: 0))

        case "K": // EL — Erase in Line
            eraseInLine(param(0, default: 0))

        case "L": // IL — Insert Lines
            insertLines(max(param(0, default: 1), 1))

        case "M": // DL — Delete Lines
            deleteLines(max(param(0, default: 1), 1))

        case "P": // DCH — Delete Characters
            deleteChars(max(param(0, default: 1), 1))

        case "S": // SU — Scroll Up
            scrollUp(count: max(param(0, default: 1), 1))

        case "T": // SD — Scroll Down
            scrollDown(count: max(param(0, default: 1), 1))

        case "X": // ECH — Erase Characters
            eraseChars(max(param(0, default: 1), 1))

        case "@": // ICH — Insert Characters
            insertChars(max(param(0, default: 1), 1))

        case "d": // VPA — Vertical Position Absolute
            let row = max(param(0, default: 1), 1) - 1
            screen.cursor.row = min(row, screen.rows - 1)

        case "m": // SGR — Select Graphic Rendition
            dispatchSGR()

        case "n": // DSR — Device Status Report
            let p = param(0, default: 0)
            if p == 6 {
                // CPR — Cursor Position Report: respond with \x1b[{row};{col}R (1-based).
                let row = screen.cursor.row + 1
                let col = screen.cursor.col + 1
                let response = Data("\u{1b}[\(row);\(col)R".utf8)
                onResponse?(response)
            } else if p == 5 {
                // Device status: respond with "OK".
                onResponse?(Data("\u{1b}[0n".utf8))
            }

        case "r": // DECSTBM — Set Scrolling Region
            let top = max(param(0, default: 1), 1) - 1
            let bottom = (params.count >= 2 ? max(param(1, default: UInt16(screen.rows)), 1) : screen.rows) - 1
            if top < bottom && bottom < screen.rows {
                screen.scrollTop = top
                screen.scrollBottom = bottom
            }
            screen.cursor.row = screen.scrollTop
            screen.cursor.col = 0

        case "s": // SCP — Save Cursor Position
            saveCursor()

        case "u": // RCP — Restore Cursor Position
            restoreCursor()

        case "t": // Window manipulation — mostly ignored
            break

        case "g": // TBC — Tab Clear
            let mode = param(0, default: 0)
            if mode == 0 {
                screen.tabStops.remove(screen.cursor.col)
            } else if mode == 3 {
                screen.tabStops.removeAll()
            }

        case "c": // DA — Device Attributes
            if intermediateChar == ">" {
                // DA2 — Secondary Device Attributes: report as VT220.
                onResponse?(Data("\u{1b}[>1;10;0c".utf8))
            } else {
                // DA1 — Primary Device Attributes: report as VT220 with ANSI color.
                onResponse?(Data("\u{1b}[?62;22c".utf8))
            }

        case "h": // SM — Set Mode
            setMode(true)

        case "l": // RM — Reset Mode
            setMode(false)

        default:
            break
        }
    }

    // MARK: - Private Mode Sequences (CSI ? ...)

    private func dispatchPrivateMode(_ ch: Character) {
        switch ch {
        case "h":
            for p in params {
                setPrivateMode(Int(p), enabled: true)
            }
        case "l":
            for p in params {
                setPrivateMode(Int(p), enabled: false)
            }
        default:
            break
        }
    }

    private func setPrivateMode(_ mode: Int, enabled: Bool) {
        switch mode {
        case 1: // DECCKM — Application Cursor Keys
            if enabled {
                terminalState.modes.insert(.applicationCursor)
            } else {
                terminalState.modes.remove(.applicationCursor)
            }
        case 6: // DECOM — Origin Mode
            if enabled {
                terminalState.modes.insert(.originMode)
            } else {
                terminalState.modes.remove(.originMode)
            }
            screen.cursor.row = screen.scrollTop
            screen.cursor.col = 0
        case 7: // DECAWM — Auto-Wrap Mode
            if enabled {
                terminalState.modes.insert(.autoWrap)
            } else {
                terminalState.modes.remove(.autoWrap)
            }
        case 12: // Start Blinking Cursor — att610
            break
        case 25: // DECTCEM — Cursor Visible
            if enabled {
                terminalState.modes.insert(.cursorVisible)
                screen.cursor.visible = true
            } else {
                terminalState.modes.remove(.cursorVisible)
                screen.cursor.visible = false
            }
        case 47: // Alternate Screen Buffer (older)
            switchScreen(toAlternate: enabled)
        case 1000: // Mouse button tracking
            if enabled {
                terminalState.modes.insert(.mouseButton)
            } else {
                terminalState.modes.remove(.mouseButton)
            }
        case 1002: // Mouse any-event tracking
            if enabled {
                terminalState.modes.insert(.mouseAny)
            } else {
                terminalState.modes.remove(.mouseAny)
            }
        case 1006: // SGR mouse mode
            if enabled {
                terminalState.modes.insert(.mouseSGR)
            } else {
                terminalState.modes.remove(.mouseSGR)
            }
        case 1004: // Focus events
            if enabled {
                terminalState.modes.insert(.focusEvents)
            } else {
                terminalState.modes.remove(.focusEvents)
            }
        case 1049: // Alternate Screen Buffer + save/restore cursor
            if enabled {
                saveCursor()
                switchScreen(toAlternate: true)
                screen.reset()
            } else {
                switchScreen(toAlternate: false)
                restoreCursor()
            }
        case 2004: // Bracketed Paste Mode
            if enabled {
                terminalState.modes.insert(.bracketedPaste)
            } else {
                terminalState.modes.remove(.bracketedPaste)
            }
        default:
            break
        }
    }

    private func switchScreen(toAlternate: Bool) {
        if toAlternate {
            terminalState.activeScreen = terminalState.alternateScreen
            terminalState.modes.insert(.alternateScreen)
        } else {
            terminalState.activeScreen = terminalState.primaryScreen
            terminalState.modes.remove(.alternateScreen)
        }
    }

    private func setMode(_ enabled: Bool) {
        for p in params {
            switch Int(p) {
            case 4: // IRM — Insert Mode
                if enabled {
                    terminalState.modes.insert(.insertMode)
                } else {
                    terminalState.modes.remove(.insertMode)
                }
            case 20: // LNM — Line Feed / New Line Mode
                if enabled {
                    terminalState.modes.insert(.lineFeedNewLine)
                } else {
                    terminalState.modes.remove(.lineFeedNewLine)
                }
            default:
                break
            }
        }
    }

    // MARK: - SGR (Select Graphic Rendition)

    private func dispatchSGR() {
        let s = screen
        if params.isEmpty {
            // ESC[m — reset
            s.currentAttributes = []
            s.currentFG = .default
            s.currentBG = .default
            return
        }

        var i = 0
        while i < params.count {
            let code = Int(params[i])
            switch code {
            case 0: // Reset
                s.currentAttributes = []
                s.currentFG = .default
                s.currentBG = .default
            case 1:
                s.currentAttributes.insert(.bold)
            case 2:
                s.currentAttributes.insert(.dim)
            case 3:
                s.currentAttributes.insert(.italic)
            case 4:
                s.currentAttributes.insert(.underline)
            case 5, 6:
                s.currentAttributes.insert(.blink)
            case 7:
                s.currentAttributes.insert(.inverse)
            case 8:
                s.currentAttributes.insert(.hidden)
            case 9:
                s.currentAttributes.insert(.strikethrough)
            case 21:
                s.currentAttributes.remove(.bold)
            case 22:
                s.currentAttributes.remove(.bold)
                s.currentAttributes.remove(.dim)
            case 23:
                s.currentAttributes.remove(.italic)
            case 24:
                s.currentAttributes.remove(.underline)
            case 25:
                s.currentAttributes.remove(.blink)
            case 27:
                s.currentAttributes.remove(.inverse)
            case 28:
                s.currentAttributes.remove(.hidden)
            case 29:
                s.currentAttributes.remove(.strikethrough)

            // Foreground colors
            case 30...37:
                s.currentFG = .indexed(UInt8(code - 30))
            case 38:
                if let (color, advance) = parseExtendedColor(from: i + 1) {
                    s.currentFG = color
                    i += advance
                }
            case 39:
                s.currentFG = .default

            // Background colors
            case 40...47:
                s.currentBG = .indexed(UInt8(code - 40))
            case 48:
                if let (color, advance) = parseExtendedColor(from: i + 1) {
                    s.currentBG = color
                    i += advance
                }
            case 49:
                s.currentBG = .default

            // Bright foreground
            case 90...97:
                s.currentFG = .indexed(UInt8(code - 90 + 8))
            // Bright background
            case 100...107:
                s.currentBG = .indexed(UInt8(code - 100 + 8))

            default:
                break
            }
            i += 1
        }
    }

    /// Parse 256-color (5;n) or true-color (2;r;g;b) from SGR params.
    /// Returns the color and how many extra params were consumed.
    private func parseExtendedColor(from index: Int) -> (TerminalColor, Int)? {
        guard index < params.count else { return nil }
        let mode = Int(params[index])
        switch mode {
        case 5: // 256-color
            guard index + 1 < params.count else { return nil }
            return (.indexed(UInt8(min(params[index + 1], 255))), 2)
        case 2: // True color
            guard index + 3 < params.count else { return nil }
            let r = UInt8(min(params[index + 1], 255))
            let g = UInt8(min(params[index + 2], 255))
            let b = UInt8(min(params[index + 3], 255))
            return (.rgb(r, g, b), 4)
        default:
            return nil
        }
    }

    // MARK: - Erase Operations

    private func eraseInDisplay(_ mode: Int) {
        let s = screen
        switch mode {
        case 0: // Erase below (cursor to end)
            eraseInLine(0) // Current line from cursor
            for row in (s.cursor.row + 1)..<s.rows {
                s.lines[row] = TerminalLine(columns: s.columns)
            }
        case 1: // Erase above (start to cursor)
            for row in 0..<s.cursor.row {
                s.lines[row] = TerminalLine(columns: s.columns)
            }
            // Current line from start to cursor
            for col in 0...min(s.cursor.col, s.columns - 1) {
                s.lines[s.cursor.row].cells[col] = .blank
            }
            s.lines[s.cursor.row].isDirty = true
        case 2: // Erase entire display
            for row in 0..<s.rows {
                s.lines[row] = TerminalLine(columns: s.columns)
            }
        case 3: // Erase scrollback (xterm extension)
            terminalState.scrollback.clear()
        default:
            break
        }
    }

    private func eraseInLine(_ mode: Int) {
        let s = screen
        let row = s.cursor.row
        guard row >= 0 && row < s.rows else { return }
        switch mode {
        case 0: // Cursor to end of line
            for col in s.cursor.col..<s.columns {
                s.lines[row].cells[col] = .blank
            }
        case 1: // Start of line to cursor
            for col in 0...min(s.cursor.col, s.columns - 1) {
                s.lines[row].cells[col] = .blank
            }
        case 2: // Entire line
            s.lines[row] = TerminalLine(columns: s.columns)
        default:
            break
        }
        s.lines[row].isDirty = true
    }

    // MARK: - Insert/Delete Operations

    private func insertLines(_ count: Int) {
        let s = screen
        guard s.cursor.row >= s.scrollTop && s.cursor.row <= s.scrollBottom else { return }
        let n = min(count, s.scrollBottom - s.cursor.row + 1)
        for _ in 0..<n {
            if s.scrollBottom < s.lines.count {
                s.lines.remove(at: s.scrollBottom)
            }
            s.lines.insert(TerminalLine(columns: s.columns), at: s.cursor.row)
        }
        // Mark dirty.
        for row in s.cursor.row...s.scrollBottom {
            s.lines[row].isDirty = true
        }
    }

    private func deleteLines(_ count: Int) {
        let s = screen
        guard s.cursor.row >= s.scrollTop && s.cursor.row <= s.scrollBottom else { return }
        let n = min(count, s.scrollBottom - s.cursor.row + 1)
        for _ in 0..<n {
            s.lines.remove(at: s.cursor.row)
            s.lines.insert(TerminalLine(columns: s.columns), at: s.scrollBottom)
        }
        for row in s.cursor.row...s.scrollBottom {
            s.lines[row].isDirty = true
        }
    }

    private func deleteChars(_ count: Int) {
        let s = screen
        let row = s.cursor.row
        guard row >= 0 && row < s.rows else { return }
        let n = min(count, s.columns - s.cursor.col)
        s.lines[row].cells.removeSubrange(s.cursor.col..<(s.cursor.col + n))
        s.lines[row].cells.append(contentsOf: Array(repeating: TerminalCell.blank, count: n))
        s.lines[row].isDirty = true
    }

    private func insertChars(_ count: Int) {
        let s = screen
        let row = s.cursor.row
        guard row >= 0 && row < s.rows else { return }
        let n = min(count, s.columns - s.cursor.col)
        let blanks = Array(repeating: TerminalCell.blank, count: n)
        s.lines[row].cells.insert(contentsOf: blanks, at: s.cursor.col)
        s.lines[row].cells.removeLast(n)
        s.lines[row].isDirty = true
    }

    private func eraseChars(_ count: Int) {
        let s = screen
        let row = s.cursor.row
        guard row >= 0 && row < s.rows else { return }
        let end = min(s.cursor.col + count, s.columns)
        for col in s.cursor.col..<end {
            s.lines[row].cells[col] = .blank
        }
        s.lines[row].isDirty = true
    }

    // MARK: - OSC Dispatch

    private func dispatchOSC() {
        guard let payload = String(bytes: oscPayload, encoding: .utf8) else { return }

        // Parse OSC number: everything before the first ';'
        guard let semicolonIndex = payload.firstIndex(of: ";") else { return }
        let oscNumberStr = payload[payload.startIndex..<semicolonIndex]
        guard let oscNumber = Int(oscNumberStr) else { return }
        let data = String(payload[payload.index(after: semicolonIndex)...])

        switch oscNumber {
        case 0, 2: // Set window title (and icon name)
            screen.title = data
        case 1: // Set icon name — treat as title
            screen.title = data
        case 52: // Clipboard
            // TODO: Handle clipboard access
            break
        case 4: // Change/query color palette entry
            break
        case 10: // Set foreground color
            break
        case 11: // Set background color
            break
        case 12: // Set cursor color
            break
        default:
            break
        }
    }

    // MARK: - UTF-8 Decoding

    private func decodeUTF8(_ bytes: [UInt8]) -> Unicode.Scalar? {
        var iterator = bytes.makeIterator()
        var codec = UTF8()
        switch codec.decode(&iterator) {
        case .scalarValue(let scalar):
            return scalar
        case .emptyInput, .error:
            return nil
        }
    }
}
