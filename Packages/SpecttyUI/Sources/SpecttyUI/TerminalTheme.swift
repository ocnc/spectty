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
        case "Catppuccin Mocha": return .catppuccinMocha
        case "Catppuccin Latte": return .catppuccinLatte
        case "Tokyo Night":      return .tokyoNight
        case "Gruvbox Dark":     return .gruvboxDark
        case "Dracula":          return .dracula
        case "Nord":             return .nord
        case "Monokai":          return .monokai
        default:                 return .default
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

    public static let catppuccinMocha = TerminalTheme(
        foreground: (205, 214, 244),
        background: (30, 30, 46),
        cursor: (245, 224, 220),
        ansiColors: [
            (69, 71, 90),      // 0  Black
            (243, 139, 168),   // 1  Red
            (166, 227, 161),   // 2  Green
            (249, 226, 175),   // 3  Yellow
            (137, 180, 250),   // 4  Blue
            (245, 194, 231),   // 5  Magenta
            (148, 226, 213),   // 6  Cyan
            (166, 173, 200),   // 7  White
            (88, 91, 112),     // 8  Bright Black
            (243, 119, 153),   // 9  Bright Red
            (137, 216, 139),   // 10 Bright Green
            (235, 211, 145),   // 11 Bright Yellow
            (116, 168, 252),   // 12 Bright Blue
            (242, 174, 222),   // 13 Bright Magenta
            (107, 215, 202),   // 14 Bright Cyan
            (186, 194, 222),   // 15 Bright White
        ]
    )

    public static let catppuccinLatte = TerminalTheme(
        foreground: (76, 79, 105),
        background: (239, 241, 245),
        cursor: (220, 138, 120),
        ansiColors: [
            (92, 95, 119),     // 0  Black
            (210, 15, 57),     // 1  Red
            (64, 160, 43),     // 2  Green
            (223, 142, 29),    // 3  Yellow
            (30, 102, 245),    // 4  Blue
            (234, 118, 203),   // 5  Magenta
            (23, 146, 153),    // 6  Cyan
            (172, 176, 190),   // 7  White
            (108, 111, 133),   // 8  Bright Black
            (222, 41, 62),     // 9  Bright Red
            (73, 175, 61),     // 10 Bright Green
            (238, 160, 45),    // 11 Bright Yellow
            (69, 110, 255),    // 12 Bright Blue
            (254, 133, 216),   // 13 Bright Magenta
            (45, 159, 168),    // 14 Bright Cyan
            (188, 192, 204),   // 15 Bright White
        ]
    )

    public static let tokyoNight = TerminalTheme(
        foreground: (192, 202, 245),
        background: (26, 27, 38),
        cursor: (192, 202, 245),
        ansiColors: [
            (21, 22, 30),      // 0  Black
            (247, 118, 142),   // 1  Red
            (158, 206, 106),   // 2  Green
            (224, 175, 104),   // 3  Yellow
            (122, 162, 247),   // 4  Blue
            (187, 154, 247),   // 5  Magenta
            (125, 207, 255),   // 6  Cyan
            (169, 177, 214),   // 7  White
            (65, 72, 104),     // 8  Bright Black
            (255, 137, 157),   // 9  Bright Red
            (159, 224, 68),    // 10 Bright Green
            (250, 186, 74),    // 11 Bright Yellow
            (141, 176, 255),   // 12 Bright Blue
            (199, 169, 255),   // 13 Bright Magenta
            (164, 218, 255),   // 14 Bright Cyan
            (192, 202, 245),   // 15 Bright White
        ]
    )

    public static let gruvboxDark = TerminalTheme(
        foreground: (235, 219, 178),
        background: (40, 40, 40),
        cursor: (235, 219, 178),
        ansiColors: [
            (40, 40, 40),      // 0  Black
            (204, 36, 29),     // 1  Red
            (152, 151, 26),    // 2  Green
            (215, 153, 33),    // 3  Yellow
            (69, 133, 136),    // 4  Blue
            (177, 98, 134),    // 5  Magenta
            (104, 157, 106),   // 6  Cyan
            (168, 153, 132),   // 7  White
            (146, 131, 116),   // 8  Bright Black
            (251, 73, 52),     // 9  Bright Red
            (184, 187, 38),    // 10 Bright Green
            (250, 189, 47),    // 11 Bright Yellow
            (131, 165, 152),   // 12 Bright Blue
            (211, 134, 155),   // 13 Bright Magenta
            (142, 192, 124),   // 14 Bright Cyan
            (235, 219, 178),   // 15 Bright White
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
