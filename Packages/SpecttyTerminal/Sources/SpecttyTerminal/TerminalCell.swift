import Foundation

/// Represents the color of a terminal cell's foreground or background.
public enum TerminalColor: Equatable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    /// Standard ANSI 256-color palette.
    public static let palette: [TerminalColor] = {
        // 0-7: Standard colors
        var colors: [TerminalColor] = [
            .rgb(0, 0, 0),       // Black
            .rgb(205, 49, 49),   // Red
            .rgb(13, 188, 121),  // Green
            .rgb(229, 229, 16),  // Yellow
            .rgb(36, 114, 200),  // Blue
            .rgb(188, 63, 188),  // Magenta
            .rgb(17, 168, 205),  // Cyan
            .rgb(229, 229, 229), // White
        ]
        // 8-15: Bright colors
        colors += [
            .rgb(102, 102, 102), // Bright Black
            .rgb(241, 76, 76),   // Bright Red
            .rgb(35, 209, 139),  // Bright Green
            .rgb(245, 245, 67),  // Bright Yellow
            .rgb(59, 142, 234),  // Bright Blue
            .rgb(214, 112, 214), // Bright Magenta
            .rgb(41, 184, 219),  // Bright Cyan
            .rgb(255, 255, 255), // Bright White
        ]
        // 16-231: 6x6x6 color cube
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    let rv = UInt8(r == 0 ? 0 : 55 + 40 * r)
                    let gv = UInt8(g == 0 ? 0 : 55 + 40 * g)
                    let bv = UInt8(b == 0 ? 0 : 55 + 40 * b)
                    colors.append(.rgb(rv, gv, bv))
                }
            }
        }
        // 232-255: Grayscale ramp
        for i in 0..<24 {
            let v = UInt8(8 + 10 * i)
            colors.append(.rgb(v, v, v))
        }
        return colors
    }()

    /// Resolve this color to RGB values given the palette.
    public func resolved(defaultColor: (UInt8, UInt8, UInt8)) -> (UInt8, UInt8, UInt8) {
        switch self {
        case .default:
            return defaultColor
        case .indexed(let idx):
            if let c = Self.palette[safe: Int(idx)] {
                switch c {
                case .rgb(let r, let g, let b): return (r, g, b)
                default: return defaultColor
                }
            }
            return defaultColor
        case .rgb(let r, let g, let b):
            return (r, g, b)
        }
    }
}

/// Text attributes for a terminal cell.
public struct CellAttributes: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold          = CellAttributes(rawValue: 1 << 0)
    public static let italic        = CellAttributes(rawValue: 1 << 1)
    public static let underline     = CellAttributes(rawValue: 1 << 2)
    public static let strikethrough = CellAttributes(rawValue: 1 << 3)
    public static let inverse       = CellAttributes(rawValue: 1 << 4)
    public static let dim           = CellAttributes(rawValue: 1 << 5)
    public static let hidden        = CellAttributes(rawValue: 1 << 6)
    public static let blink         = CellAttributes(rawValue: 1 << 7)
    public static let wideChar      = CellAttributes(rawValue: 1 << 8)
    public static let wideCharTail  = CellAttributes(rawValue: 1 << 9)
}

/// A single cell in the terminal grid.
public struct TerminalCell: Equatable, Sendable {
    /// The character displayed in this cell. Empty string means blank.
    public var character: Character

    /// Foreground color.
    public var fg: TerminalColor

    /// Background color.
    public var bg: TerminalColor

    /// Text attributes.
    public var attributes: CellAttributes

    /// A blank cell with default colors.
    public static let blank = TerminalCell(
        character: " ",
        fg: .default,
        bg: .default,
        attributes: []
    )

    public init(character: Character, fg: TerminalColor, bg: TerminalColor, attributes: CellAttributes) {
        self.character = character
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }
}

/// A line of terminal cells.
public struct TerminalLine: Sendable {
    public var cells: [TerminalCell]
    public var isDirty: Bool

    public init(columns: Int) {
        cells = Array(repeating: .blank, count: columns)
        isDirty = true
    }

    public init(cells: [TerminalCell]) {
        self.cells = cells
        self.isDirty = true
    }

    public mutating func resize(columns: Int) {
        if columns > cells.count {
            cells.append(contentsOf: Array(repeating: .blank, count: columns - cells.count))
        } else if columns < cells.count {
            cells.removeLast(cells.count - columns)
        }
        isDirty = true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
