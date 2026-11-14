import Foundation
import SpecttyTerminal

/// Uses the same rows for rendering, selection, and link hit testing.
enum TerminalText {
    static func visibleLines(state: TerminalScreenState, scrollback: TerminalBuffer, scrollOffset: Int) -> [TerminalLine] {
        let offset = min(max(0, scrollOffset), scrollback.count)
        return (0..<state.rows).map { row in
            let index = scrollback.count - offset + row
            if index < scrollback.count, let line = scrollback.line(at: index) { return line }
            return state.lines[index - scrollback.count]
        }
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func link(atRow row: Int, col: Int, in lines: [TerminalLine]) -> (url: URL, selection: TerminalSelection)? {
        guard lines.indices.contains(row), lines[row].cells.indices.contains(col) else { return nil }
        var first = row
        var last = row
        while first > 0 && lines[first - 1].wrappedColumns != nil { first -= 1 }
        while last + 1 < lines.count && lines[last].wrappedColumns != nil { last += 1 }

        var text = ""
        var utf16Count = 0
        var cells: [(row: Int, col: Int, width: Int, range: NSRange)] = []
        for r in first...last {
            let line = lines[r]
            for c in 0..<min(line.cells.count, line.wrappedColumns ?? line.cells.count) {
                let cell = line.cells[c]
                guard !cell.isWideTail else { continue }
                let value = String(cell.character)
                cells.append((r, c, cell.isWideHead ? 2 : 1, NSRange(location: utf16Count, length: value.utf16.count)))
                text += value
                utf16Count += value.utf16.count
            }
        }
        guard let tapped = cells.first(where: { $0.row == row && col >= $0.col && col < $0.col + $0.width }) else { return nil }
        let matches = linkDetector?.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) ?? []
        guard let match = matches.first(where: { NSIntersectionRange($0.range, tapped.range).length > 0 }),
              let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let start = cells.first(where: { NSIntersectionRange($0.range, match.range).length > 0 }),
              let end = cells.last(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { return nil }
        return (url, TerminalSelection(startRow: start.row, startCol: start.col, endRow: end.row, endCol: end.col))
    }
}
