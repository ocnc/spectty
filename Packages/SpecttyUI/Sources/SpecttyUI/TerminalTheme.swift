import Foundation

/// Cursor drawing style.
public enum CursorStyle: String, Sendable {
    case block
    case underline
    case bar
}

/// Color palette for a terminal theme.
public struct TerminalTheme: Sendable {
    public var foreground: (UInt8, UInt8, UInt8)
    public var background: (UInt8, UInt8, UInt8)
    public var cursor: (UInt8, UInt8, UInt8)
    /// ANSI colors 0-15 (standard 8 + bright 8).
    public var ansiColors: [(UInt8, UInt8, UInt8)]

    public init(
        foreground: (UInt8, UInt8, UInt8),
        background: (UInt8, UInt8, UInt8),
        cursor: (UInt8, UInt8, UInt8),
        ansiColors: [(UInt8, UInt8, UInt8)]
    ) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.ansiColors = ansiColors
    }

    /// Look up a theme by name (matches the SettingsView picker values).
    public static func named(_ name: String) -> TerminalTheme {
        switch name {
        case "Solarized Dark":  return .solarizedDark
        case "Solarized Light": return .solarizedLight
        case "Dracula":         return .dracula
        case "Nord":            return .nord
        case "Monokai":         return .monokai
        default:                return .default
        }
    }

    // MARK: - Built-in Themes

    public static let `default` = TerminalTheme(
        foreground: (229, 229, 229),
        background: (30, 30, 30),
        cursor: (229, 229, 229),
        ansiColors: [
            (0, 0, 0),         // 0  Black
            (205, 49, 49),     // 1  Red
            (13, 188, 121),    // 2  Green
            (229, 229, 16),    // 3  Yellow
            (36, 114, 200),    // 4  Blue
            (188, 63, 188),    // 5  Magenta
            (17, 168, 205),    // 6  Cyan
            (229, 229, 229),   // 7  White
            (102, 102, 102),   // 8  Bright Black
            (241, 76, 76),     // 9  Bright Red
            (35, 209, 139),    // 10 Bright Green
            (245, 245, 67),    // 11 Bright Yellow
            (59, 142, 234),    // 12 Bright Blue
            (214, 112, 214),   // 13 Bright Magenta
            (41, 184, 219),    // 14 Bright Cyan
            (255, 255, 255),   // 15 Bright White
        ]
    )

    public static let solarizedDark = TerminalTheme(
        foreground: (131, 148, 150),
        background: (0, 43, 54),
        cursor: (131, 148, 150),
        ansiColors: [
            (7, 54, 66),       // 0  Black
            (220, 50, 47),     // 1  Red
            (133, 153, 0),     // 2  Green
            (181, 137, 0),     // 3  Yellow
            (38, 139, 210),    // 4  Blue
            (211, 54, 130),    // 5  Magenta
            (42, 161, 152),    // 6  Cyan
            (238, 232, 213),   // 7  White
            (0, 43, 54),       // 8  Bright Black
            (203, 75, 22),     // 9  Bright Red
            (88, 110, 117),    // 10 Bright Green
            (101, 123, 131),   // 11 Bright Yellow
            (131, 148, 150),   // 12 Bright Blue
            (108, 113, 196),   // 13 Bright Magenta
            (147, 161, 161),   // 14 Bright Cyan
            (253, 246, 227),   // 15 Bright White
        ]
    )

    public static let solarizedLight = TerminalTheme(
        foreground: (101, 123, 131),
        background: (253, 246, 227),
        cursor: (101, 123, 131),
        ansiColors: [
            (7, 54, 66),       // 0  Black
            (220, 50, 47),     // 1  Red
            (133, 153, 0),     // 2  Green
            (181, 137, 0),     // 3  Yellow
            (38, 139, 210),    // 4  Blue
            (211, 54, 130),    // 5  Magenta
            (42, 161, 152),    // 6  Cyan
            (238, 232, 213),   // 7  White
            (0, 43, 54),       // 8  Bright Black
            (203, 75, 22),     // 9  Bright Red
            (88, 110, 117),    // 10 Bright Green
            (101, 123, 131),   // 11 Bright Yellow
            (131, 148, 150),   // 12 Bright Blue
            (108, 113, 196),   // 13 Bright Magenta
            (147, 161, 161),   // 14 Bright Cyan
            (253, 246, 227),   // 15 Bright White
        ]
    )

    public static let dracula = TerminalTheme(
        foreground: (248, 248, 242),
        background: (40, 42, 54),
        cursor: (248, 248, 242),
        ansiColors: [
            (33, 34, 44),      // 0  Black
            (255, 85, 85),     // 1  Red
            (80, 250, 123),    // 2  Green
            (241, 250, 140),   // 3  Yellow
            (189, 147, 249),   // 4  Blue
            (255, 121, 198),   // 5  Magenta
            (139, 233, 253),   // 6  Cyan
            (248, 248, 242),   // 7  White
            (98, 114, 164),    // 8  Bright Black
            (255, 110, 110),   // 9  Bright Red
            (105, 255, 148),   // 10 Bright Green
            (255, 255, 165),   // 11 Bright Yellow
            (214, 172, 255),   // 12 Bright Blue
            (255, 146, 223),   // 13 Bright Magenta
            (164, 255, 255),   // 14 Bright Cyan
            (255, 255, 255),   // 15 Bright White
        ]
    )

    public static let nord = TerminalTheme(
        foreground: (216, 222, 233),
        background: (46, 52, 64),
        cursor: (216, 222, 233),
        ansiColors: [
            (59, 66, 82),      // 0  Black
            (191, 97, 106),    // 1  Red
            (163, 190, 140),   // 2  Green
            (235, 203, 139),   // 3  Yellow
            (129, 161, 193),   // 4  Blue
            (180, 142, 173),   // 5  Magenta
            (136, 192, 208),   // 6  Cyan
            (229, 233, 240),   // 7  White
            (76, 86, 106),     // 8  Bright Black
            (191, 97, 106),    // 9  Bright Red
            (163, 190, 140),   // 10 Bright Green
            (235, 203, 139),   // 11 Bright Yellow
            (129, 161, 193),   // 12 Bright Blue
            (180, 142, 173),   // 13 Bright Magenta
            (143, 188, 187),   // 14 Bright Cyan
            (236, 239, 244),   // 15 Bright White
        ]
    )

    public static let monokai = TerminalTheme(
        foreground: (248, 248, 242),
        background: (39, 40, 34),
        cursor: (248, 248, 240),
        ansiColors: [
            (39, 40, 34),      // 0  Black
            (249, 38, 114),    // 1  Red
            (166, 226, 46),    // 2  Green
            (244, 191, 117),   // 3  Yellow
            (102, 217, 239),   // 4  Blue
            (174, 129, 255),   // 5  Magenta
            (161, 239, 228),   // 6  Cyan
            (248, 248, 242),   // 7  White
            (117, 113, 94),    // 8  Bright Black
            (249, 38, 114),    // 9  Bright Red
            (166, 226, 46),    // 10 Bright Green
            (244, 191, 117),   // 11 Bright Yellow
            (102, 217, 239),   // 12 Bright Blue
            (174, 129, 255),   // 13 Bright Magenta
            (161, 239, 228),   // 14 Bright Cyan
            (249, 248, 245),   // 15 Bright White
        ]
    )
}
