import UIKit

enum HardwareKeyInterpreter {
    static func terminalCharacters(
        rawCharacters: String,
        charactersIgnoringModifiers: String,
        modifiers: UIKeyModifierFlags
    ) -> String {
        let normalizedModifiers = modifiers.intersection([.shift, .alternate, .control, .command])

        guard normalizedModifiers.intersection([.alternate, .control, .command]).isEmpty == false else {
            return rawCharacters
        }

        if isPrintableASCII(rawCharacters) {
            return rawCharacters
        }

        guard let normalizedBase = normalizedTerminalBaseCharacter(
            charactersIgnoringModifiers,
            modifiers: normalizedModifiers
        ) else {
            return rawCharacters
        }

        // iOS Option layers can replace the base key with a printable
        // non-ASCII glyph (for example Option-F -> "ƒ"). Terminals expect the
        // ASCII base key with the Alt modifier preserved so Meta works.
        if normalizedModifiers.contains(.alternate),
           isPrintableNonASCII(rawCharacters),
           normalizedBase.canBeConverted(to: .ascii) {
            return normalizedBase
        }

        if rawCharacters.isEmpty ||
            rawCharacters.rangeOfCharacter(from: .controlCharacters) != nil {
            return normalizedBase
        }

        return rawCharacters
    }

    private static func normalizedTerminalBaseCharacter(
        _ charactersIgnoringModifiers: String,
        modifiers: UIKeyModifierFlags
    ) -> String? {
        guard !charactersIgnoringModifiers.isEmpty else { return nil }

        guard modifiers.contains(.shift) else {
            return charactersIgnoringModifiers
        }

        if charactersIgnoringModifiers.count == 1,
           let scalar = charactersIgnoringModifiers.unicodeScalars.first,
           CharacterSet.letters.contains(scalar) {
            return charactersIgnoringModifiers.uppercased()
        }

        switch charactersIgnoringModifiers {
        case "1": return "!"
        case "2": return "@"
        case "3": return "#"
        case "4": return "$"
        case "5": return "%"
        case "6": return "^"
        case "7": return "&"
        case "8": return "*"
        case "9": return "("
        case "0": return ")"
        case "-": return "_"
        case "=": return "+"
        case "[": return "{"
        case "]": return "}"
        case "\\": return "|"
        case ";": return ":"
        case "'": return "\""
        case ",": return "<"
        case ".": return ">"
        case "/": return "?"
        case "`": return "~"
        default:
            return charactersIgnoringModifiers
        }
    }

    private static func isPrintableASCII(_ value: String) -> Bool {
        !value.isEmpty &&
        value.rangeOfCharacter(from: .controlCharacters) == nil &&
        value.canBeConverted(to: .ascii)
    }

    private static func isPrintableNonASCII(_ value: String) -> Bool {
        !value.isEmpty &&
        value.rangeOfCharacter(from: .controlCharacters) == nil &&
        !value.canBeConverted(to: .ascii)
    }
}

