import Foundation

/// Encodes key events into escape sequences for the terminal.
///
/// This is a Swift implementation that handles standard xterm key encoding.
/// Can be swapped for libghostty-vt's `ghostty_key_encode` via the same interface.
public struct KeyEncoder: Sendable {
    public init() {}

    /// Encode a key event given the current terminal modes.
    public func encode(_ event: KeyEvent, modes: TerminalModes) -> Data {
        guard event.isKeyDown else { return Data() }

        let applicationCursor = modes.contains(.applicationCursor)

        // Shift+Tab → backtab (CSI Z).
        if event.keyCode == Self.keyTab && event.modifiers.contains(.shift) {
            return Data("\u{1B}[Z".utf8)
        }

        // If the key has printable characters and no special modifiers beyond shift,
        // just send the characters.
        if !event.characters.isEmpty && event.modifiers.subtracting(.shift).isEmpty {
            // Check if it's a special key first.
            if let special = encodeSpecialKey(event.keyCode, applicationCursor: applicationCursor) {
                return Data(special.utf8)
            }

            // Control key combinations.
            if event.modifiers.contains(.control) {
                return encodeControl(event.characters)
            }

            return Data(event.characters.utf8)
        }

        // Handle control key.
        if event.modifiers.contains(.control) && !event.characters.isEmpty {
            return encodeControl(event.characters)
        }

        // Handle special keys (arrows, function keys, etc.).
        if let special = encodeSpecialKey(event.keyCode, applicationCursor: applicationCursor) {
            if event.modifiers.isEmpty {
                return Data(special.utf8)
            }
            // Modified special key: CSI 1;mod final
            return encodeModifiedSpecial(special, modifiers: event.modifiers)
        }

        // Fallback: send characters if we have them.
        if !event.characters.isEmpty {
            return Data(event.characters.utf8)
        }

        return Data()
    }

    // MARK: - Special Keys

    // USB HID keycodes for common keys.
    private static let keyUp: UInt32 = 0x52
    private static let keyDown: UInt32 = 0x51
    private static let keyRight: UInt32 = 0x4F
    private static let keyLeft: UInt32 = 0x50
    private static let keyHome: UInt32 = 0x4A
    private static let keyEnd: UInt32 = 0x4D
    private static let keyPageUp: UInt32 = 0x4B
    private static let keyPageDown: UInt32 = 0x4E
    private static let keyInsert: UInt32 = 0x49
    private static let keyDelete: UInt32 = 0x4C
    private static let keyF1: UInt32 = 0x3A
    private static let keyF2: UInt32 = 0x3B
    private static let keyF3: UInt32 = 0x3C
    private static let keyF4: UInt32 = 0x3D
    private static let keyF5: UInt32 = 0x3E
    private static let keyF6: UInt32 = 0x3F
    private static let keyF7: UInt32 = 0x40
    private static let keyF8: UInt32 = 0x41
    private static let keyF9: UInt32 = 0x42
    private static let keyF10: UInt32 = 0x43
    private static let keyF11: UInt32 = 0x44
    private static let keyF12: UInt32 = 0x45
    private static let keyTab: UInt32 = 0x2B
    private static let keyReturn: UInt32 = 0x28
    private static let keyEscape: UInt32 = 0x29
    private static let keyBackspace: UInt32 = 0x2A

    private func encodeSpecialKey(_ keyCode: UInt32, applicationCursor: Bool) -> String? {
        switch keyCode {
        case Self.keyUp:
            return applicationCursor ? "\u{1B}OA" : "\u{1B}[A"
        case Self.keyDown:
            return applicationCursor ? "\u{1B}OB" : "\u{1B}[B"
        case Self.keyRight:
            return applicationCursor ? "\u{1B}OC" : "\u{1B}[C"
        case Self.keyLeft:
            return applicationCursor ? "\u{1B}OD" : "\u{1B}[D"
        case Self.keyHome:
            return applicationCursor ? "\u{1B}OH" : "\u{1B}[H"
        case Self.keyEnd:
            return applicationCursor ? "\u{1B}OF" : "\u{1B}[F"
        case Self.keyPageUp:
            return "\u{1B}[5~"
        case Self.keyPageDown:
            return "\u{1B}[6~"
        case Self.keyInsert:
            return "\u{1B}[2~"
        case Self.keyDelete:
            return "\u{1B}[3~"
        case Self.keyF1:
            return "\u{1B}OP"
        case Self.keyF2:
            return "\u{1B}OQ"
        case Self.keyF3:
            return "\u{1B}OR"
        case Self.keyF4:
            return "\u{1B}OS"
        case Self.keyF5:
            return "\u{1B}[15~"
        case Self.keyF6:
            return "\u{1B}[17~"
        case Self.keyF7:
            return "\u{1B}[18~"
        case Self.keyF8:
            return "\u{1B}[19~"
        case Self.keyF9:
            return "\u{1B}[20~"
        case Self.keyF10:
            return "\u{1B}[21~"
        case Self.keyF11:
            return "\u{1B}[23~"
        case Self.keyF12:
            return "\u{1B}[24~"
        case Self.keyTab:
            return "\t"
        case Self.keyReturn:
            return "\r"
        case Self.keyEscape:
            return "\u{1B}"
        case Self.keyBackspace:
            return "\u{7F}"
        default:
            return nil
        }
    }

    // MARK: - Control Characters

    private func encodeControl(_ characters: String) -> Data {
        guard let first = characters.first else { return Data() }
        let scalar = first.asciiValue ?? 0
        // Ctrl+A = 0x01, Ctrl+Z = 0x1A
        if scalar >= 0x61 && scalar <= 0x7A { // a-z
            return Data([scalar - 0x60])
        }
        if scalar >= 0x41 && scalar <= 0x5A { // A-Z
            return Data([scalar - 0x40])
        }
        // Special control keys.
        switch first {
        case "[", "{": return Data([0x1B])
        case "\\": return Data([0x1C])
        case "]", "}": return Data([0x1D])
        case "^", "~": return Data([0x1E])
        case "_": return Data([0x1F])
        case "@", " ": return Data([0x00])
        default:
            return Data(characters.utf8)
        }
    }

    // MARK: - Modified Special Keys

    private func encodeModifiedSpecial(_ base: String, modifiers: KeyModifiers) -> Data {
        // xterm modifier encoding: 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0) + (meta ? 8 : 0)
        var mod = 1
        if modifiers.contains(.shift) { mod += 1 }
        if modifiers.contains(.alt) { mod += 2 }
        if modifiers.contains(.control) { mod += 4 }
        if modifiers.contains(.super) { mod += 8 }

        // For SS3 sequences (ESC O X), convert to CSI 1;mod X.
        if base.hasPrefix("\u{1B}O") && base.count == 3 {
            let final = base.last!
            return Data("\u{1B}[1;\(mod)\(final)".utf8)
        }

        // For CSI sequences (ESC [ ... X or ESC [ num ~), insert modifier.
        if base.hasPrefix("\u{1B}[") {
            let body = String(base.dropFirst(2))
            if body.hasSuffix("~") {
                // ESC [ num ~ → ESC [ num;mod ~
                let num = String(body.dropLast())
                return Data("\u{1B}[\(num);\(mod)~".utf8)
            } else {
                // ESC [ X → ESC [ 1;mod X
                let final = body.last!
                return Data("\u{1B}[1;\(mod)\(final)".utf8)
            }
        }

        return Data(base.utf8)
    }
}
