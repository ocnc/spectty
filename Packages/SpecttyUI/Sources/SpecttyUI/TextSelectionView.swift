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

/// Overlay view for rendering text selection highlight and drag handles.
public final class TextSelectionView: UIView {

    /// Callback when handles are dragged. The view updates its own `selection`,
    /// but the parent needs this to keep GestureHandler state in sync.
    public var onSelectionChanged: ((TerminalSelection?) -> Void)?

    public var selection: TerminalSelection? {
        didSet { setNeedsDisplay() }
    }

    public var cellSize: CGSize = CGSize(width: 8, height: 16)
    public var selectionColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.3)

    // MARK: - Handle drag state

    private enum DragHandle { case start, end }
    private var activeHandle: DragHandle?

    /// Grab radius — how close a touch needs to be to a handle to grab it.
    private let handleHitRadius: CGFloat = 28
    /// Visual handle size.
    private let handleRadius: CGFloat = 5
    private let handleStemHeight: CGFloat = 4

    private let feedbackGenerator = UISelectionFeedbackGenerator()

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        // We handle hit testing ourselves — pass through when no handle is near.
        isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    // MARK: - Hit Testing

    /// Only intercept touches near a drag handle. Everything else passes through
    /// to the terminal view underneath.
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let sel = selection?.normalized else { return nil }

        let startCenter = handleCenter(for: sel, handle: .start)
        let endCenter = handleCenter(for: sel, handle: .end)

        let nearStart = hypot(point.x - startCenter.x, point.y - startCenter.y) <= handleHitRadius
        let nearEnd = hypot(point.x - endCenter.x, point.y - endCenter.y) <= handleHitRadius

        if nearStart || nearEnd {
            return self
        }
        return nil
    }

    // MARK: - Handle Geometry

    /// Center point of a handle in view coordinates.
    private func handleCenter(for sel: TerminalSelection, handle: DragHandle) -> CGPoint {
        switch handle {
        case .start:
            // Top-left of the start cell, handle sits above the selection.
            let x = CGFloat(sel.startCol) * cellSize.width
            let y = CGFloat(sel.startRow) * cellSize.height
            return CGPoint(x: x, y: y - handleStemHeight - handleRadius)
        case .end:
            // Bottom-right of the end cell, handle sits below the selection.
            let x = CGFloat(sel.endCol + 1) * cellSize.width
            let y = CGFloat(sel.endRow + 1) * cellSize.height
            return CGPoint(x: x, y: y + handleStemHeight + handleRadius)
        }
    }

    // MARK: - Drawing

    public override func draw(_ rect: CGRect) {
        guard let selection = selection?.normalized, let ctx = UIGraphicsGetCurrentContext() else {
            return
        }

        drawHighlight(selection, in: ctx)
        drawHandle(selection, handle: .start, in: ctx)
        drawHandle(selection, handle: .end, in: ctx)
    }

    private func drawHighlight(_ selection: TerminalSelection, in ctx: CGContext) {
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

    private func drawHandle(_ selection: TerminalSelection, handle: DragHandle, in ctx: CGContext) {
        let handleColor = UIColor.systemBlue
        ctx.setFillColor(handleColor.cgColor)
        ctx.setStrokeColor(handleColor.cgColor)
        ctx.setLineWidth(2)

        let center = handleCenter(for: selection, handle: handle)

        switch handle {
        case .start:
            // Stem from top-left of start cell down to circle.
            let anchorX = CGFloat(selection.startCol) * cellSize.width
            let anchorY = CGFloat(selection.startRow) * cellSize.height
            ctx.move(to: CGPoint(x: anchorX, y: anchorY))
            ctx.addLine(to: CGPoint(x: center.x, y: center.y + handleRadius))
            ctx.strokePath()
        case .end:
            // Stem from bottom-right of end cell up to circle.
            let anchorX = CGFloat(selection.endCol + 1) * cellSize.width
            let anchorY = CGFloat(selection.endRow + 1) * cellSize.height
            ctx.move(to: CGPoint(x: anchorX, y: anchorY))
            ctx.addLine(to: CGPoint(x: center.x, y: center.y - handleRadius))
            ctx.strokePath()
        }

        // Circle.
        let circleRect = CGRect(
            x: center.x - handleRadius,
            y: center.y - handleRadius,
            width: handleRadius * 2,
            height: handleRadius * 2
        )
        ctx.fillEllipse(in: circleRect)
    }

    // MARK: - Pan Gesture (Handle Drag)

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard var sel = selection?.normalized else { return }

        let point = gesture.location(in: self)
        let col = max(0, min(Int(point.x / cellSize.width), Int(bounds.width / cellSize.width) - 1))
        let row = max(0, min(Int(point.y / cellSize.height), Int(bounds.height / cellSize.height) - 1))

        switch gesture.state {
        case .began:
            let startCenter = handleCenter(for: sel, handle: .start)
            let endCenter = handleCenter(for: sel, handle: .end)
            let distStart = hypot(point.x - startCenter.x, point.y - startCenter.y)
            let distEnd = hypot(point.x - endCenter.x, point.y - endCenter.y)
            activeHandle = distStart < distEnd ? .start : .end
            feedbackGenerator.prepare()
            feedbackGenerator.selectionChanged()

        case .changed:
            guard let handle = activeHandle else { return }
            switch handle {
            case .start:
                sel.startRow = row
                sel.startCol = col
            case .end:
                sel.endRow = row
                sel.endCol = col
            }
            // Store un-normalized so the handle you're dragging stays as start/end.
            selection = sel
            onSelectionChanged?(sel)
            feedbackGenerator.selectionChanged()

        case .ended, .cancelled, .failed:
            activeHandle = nil

            // Show copy menu after handle drag finishes.
            if gesture.state == .ended, let sel = selection?.normalized {
                let midRow = (sel.startRow + sel.endRow) / 2
                let menuRect = CGRect(
                    x: CGFloat(sel.startCol) * cellSize.width,
                    y: CGFloat(midRow) * cellSize.height,
                    width: CGFloat(sel.endCol - sel.startCol + 1) * cellSize.width,
                    height: cellSize.height
                )
                // Find the parent responder to show the menu from.
                if let parent = superview {
                    let menu = UIMenuController.shared
                    menu.showMenu(from: parent, rect: menuRect)
                }
            }

        default:
            break
        }
    }

    // MARK: - Text Extraction

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
