import UIKit
import SpecttyTerminal

/// Selection range in terminal grid coordinates.
public struct TerminalSelection: Equatable, Sendable {
    public var startRow: Int
    public var startCol: Int
    public var endRow: Int
    public var endCol: Int

    public init(startRow: Int, startCol: Int, endRow: Int, endCol: Int) {
        self.startRow = startRow
        self.startCol = startCol
        self.endRow = endRow
        self.endCol = endCol
    }

    /// Returns the selection with start before end (normalized).
    public var normalized: TerminalSelection {
        if startRow < endRow || (startRow == endRow && startCol <= endCol) {
            return self
        }
        return TerminalSelection(startRow: endRow, startCol: endCol, endRow: startRow, endCol: startCol)
    }

    /// Check if a cell is within this selection.
    public func contains(row: Int, col: Int) -> Bool {
        let norm = normalized
        if row < norm.startRow || row > norm.endRow { return false }
        if row == norm.startRow && row == norm.endRow {
            return col >= norm.startCol && col <= norm.endCol
        }
        if row == norm.startRow { return col >= norm.startCol }
        if row == norm.endRow { return col <= norm.endCol }
        return true
    }
}

/// Overlay view for rendering text selection handles and highlight.
/// This will be a Phase 2 feature — stub for now.
public final class TextSelectionView: UIView {
    public var selection: TerminalSelection? {
        didSet { setNeedsDisplay() }
    }

    public var cellSize: CGSize = CGSize(width: 8, height: 16)
    public var selectionColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.3)

    public override func draw(_ rect: CGRect) {
        guard let selection = selection?.normalized, let ctx = UIGraphicsGetCurrentContext() else {
            return
        }

        ctx.setFillColor(selectionColor.cgColor)

        for row in selection.startRow...selection.endRow {
            let startCol: Int
            let endCol: Int

            if row == selection.startRow && row == selection.endRow {
                startCol = selection.startCol
                endCol = selection.endCol
            } else if row == selection.startRow {
                startCol = selection.startCol
                endCol = Int(bounds.width / cellSize.width)
            } else if row == selection.endRow {
                startCol = 0
                endCol = selection.endCol
            } else {
                startCol = 0
                endCol = Int(bounds.width / cellSize.width)
            }

            let rect = CGRect(
                x: CGFloat(startCol) * cellSize.width,
                y: CGFloat(row) * cellSize.height,
                width: CGFloat(endCol - startCol + 1) * cellSize.width,
                height: cellSize.height
            )
            ctx.fill(rect)
        }
    }

    /// Extract selected text from the terminal state.
    public func selectedText(from state: TerminalScreenState) -> String? {
        guard let selection = selection?.normalized else { return nil }

        var text = ""
        for row in selection.startRow...selection.endRow {
            guard row >= 0 && row < state.rows else { continue }
            let line = state.lines[row]
            let startCol = (row == selection.startRow) ? selection.startCol : 0
            let endCol = (row == selection.endRow) ? selection.endCol : state.columns - 1

            for col in startCol...min(endCol, line.cells.count - 1) {
                text.append(line.cells[col].character)
            }

            if row < selection.endRow {
                text.append("\n")
            }
        }

        // Trim trailing whitespace from each line.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }
}
