import Foundation
import GhosttyVt

/// Converts UIKit USB HID events to the native terminal's input protocol.
public struct KeyEncoder: Sendable {
    public init() {}

    public func encode(_ event: KeyEvent, modes: TerminalModes) -> Data {
        encode(event, modes: modes, terminal: nil)
    }

    func encode(_ event: KeyEvent, modes: TerminalModes, terminal: GhosttyTerminal?) -> Data {
        var encoder: GhosttyKeyEncoder?
        guard ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS else { return Data() }
        defer { ghostty_key_encoder_free(encoder) }
        if let terminal {
            ghostty_key_encoder_set_from_terminal(encoder, terminal)
        } else {
            var cursor = modes.contains(.applicationCursor)
            var keypad = modes.contains(.applicationKeypad)
            ghostty_key_encoder_set(encoder, GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION, &cursor)
            ghostty_key_encoder_set(encoder, GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION, &keypad)
        }
        var altPrefix = true
        ghostty_key_encoder_set(encoder, GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX, &altPrefix)
        var optionAsAlt = GHOSTTY_OPTION_AS_ALT_TRUE
        ghostty_key_encoder_set(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)
        var native: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &native) == GHOSTTY_SUCCESS else { return Data() }
        defer { ghostty_key_event_free(native) }
        ghostty_key_event_set_action(native, event.isKeyDown ? GHOSTTY_KEY_ACTION_PRESS : GHOSTTY_KEY_ACTION_RELEASE)
        ghostty_key_event_set_key(native, Self.key(event.keyCode))
        var mods: UInt16 = 0
        if event.modifiers.contains(.shift) { mods |= UInt16(GHOSTTY_MODS_SHIFT) }
        if event.modifiers.contains(.control) { mods |= UInt16(GHOSTTY_MODS_CTRL) }
        if event.modifiers.contains(.alt) { mods |= UInt16(GHOSTTY_MODS_ALT) }
        if event.modifiers.contains(.super) { mods |= UInt16(GHOSTTY_MODS_SUPER) }
        ghostty_key_event_set_mods(native, mods)
        let text = event.characters.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }
        let utf8 = Array(String(String.UnicodeScalarView(text)).utf8)
        // Committed text has no physical key; inventing one truncates IME text in Kitty report-all mode.
        let pureText = event.keyCode == 0 && event.modifiers.isEmpty && event.unshiftedCharacters == nil
        let unshifted = pureText ? 0 : (event.unshiftedCharacters ?? event.characters.lowercased()).unicodeScalars.first?.value ?? 0
        ghostty_key_event_set_unshifted_codepoint(native, unshifted)
        return utf8.withUnsafeBufferPointer { bytes in
            ghostty_key_event_set_utf8(native, GhosttyString(ptr: bytes.baseAddress, len: bytes.count))
            var buffer = [UInt8](repeating: 0, count: max(128, bytes.count + 32))
            var count = 0
            var result = ghostty_key_encoder_encode(encoder, native, &buffer, buffer.count, &count)
            if result == GHOSTTY_OUT_OF_SPACE {
                buffer = [UInt8](repeating: 0, count: count)
                result = ghostty_key_encoder_encode(encoder, native, &buffer, buffer.count, &count)
            }
            return result == GHOSTTY_SUCCESS ? Data(buffer.prefix(count)) : Data()
        }
    }

    private static func key(_ hid: UInt32) -> GhosttyKey {
        switch hid {
        case 0x04...0x1D: return GhosttyKey(rawValue: GHOSTTY_KEY_A.rawValue + hid - 0x04)
        case 0x1E...0x26: return GhosttyKey(rawValue: GHOSTTY_KEY_DIGIT_1.rawValue + hid - 0x1E)
        case 0x27: return GHOSTTY_KEY_DIGIT_0
        case 0x28: return GHOSTTY_KEY_ENTER
        case 0x29: return GHOSTTY_KEY_ESCAPE
        case 0x2A: return GHOSTTY_KEY_BACKSPACE
        case 0x2B: return GHOSTTY_KEY_TAB
        case 0x2C: return GHOSTTY_KEY_SPACE
        case 0x2D: return GHOSTTY_KEY_MINUS
        case 0x2E: return GHOSTTY_KEY_EQUAL
        case 0x2F: return GHOSTTY_KEY_BRACKET_LEFT
        case 0x30: return GHOSTTY_KEY_BRACKET_RIGHT
        case 0x31: return GHOSTTY_KEY_BACKSLASH
        case 0x33: return GHOSTTY_KEY_SEMICOLON
        case 0x34: return GHOSTTY_KEY_QUOTE
        case 0x35: return GHOSTTY_KEY_BACKQUOTE
        case 0x36: return GHOSTTY_KEY_COMMA
        case 0x37: return GHOSTTY_KEY_PERIOD
        case 0x38: return GHOSTTY_KEY_SLASH
        case 0x3A...0x45: return GhosttyKey(rawValue: GHOSTTY_KEY_F1.rawValue + hid - 0x3A)
        case 0x49: return GHOSTTY_KEY_INSERT
        case 0x4A: return GHOSTTY_KEY_HOME
        case 0x4B: return GHOSTTY_KEY_PAGE_UP
        case 0x4C: return GHOSTTY_KEY_DELETE
        case 0x4D: return GHOSTTY_KEY_END
        case 0x4E: return GHOSTTY_KEY_PAGE_DOWN
        case 0x4F: return GHOSTTY_KEY_ARROW_RIGHT
        case 0x50: return GHOSTTY_KEY_ARROW_LEFT
        case 0x51: return GHOSTTY_KEY_ARROW_DOWN
        case 0x52: return GHOSTTY_KEY_ARROW_UP
        default: return GHOSTTY_KEY_UNIDENTIFIED
        }
    }
}
