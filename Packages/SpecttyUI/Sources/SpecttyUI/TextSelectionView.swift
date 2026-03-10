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

    /// Callback to request the edit menu at a given point (in superview coordinates).
    public var onShowMenu: ((CGPoint) -> Void)?

    public var selection: TerminalSelection? {
        didSet { setNeedsDisplay() }
    }

    public var cellSize: CGSize = CGSize(width: 8, height: 16)
    public var selectionColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.3)
    public var contentInsets: UIEdgeInsets = .zero {
        didSet { setNeedsDisplay() }
    }

    // MARK: - Handle drag state

    private enum DragHandle { case start, end }
    private var activeHandle: DragHandle?
    /// Last grid position during drag — only fire haptic when cell changes.
    private var lastDragRow: Int = -1
    private var lastDragCol: Int = -1

    /// Grab radius — how close a touch needs to be to a handle to grab it.
    private let handleHitRadius: CGFloat = 28
    /// Visual handle size.
    private let handleRadius: CGFloat = 5
    private let handleStemHeight: CGFloat = 4

    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

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

    private var contentRect: CGRect {
        let width = max(0, bounds.width - contentInsets.left - contentInsets.right)
        let height = max(0, bounds.height - contentInsets.top - contentInsets.bottom)
        return CGRect(x: contentInsets.left, y: contentInsets.top, width: width, height: height)
    }

    private var gridColumns: Int {
        guard cellSize.width > 0 else { return 1 }
        return max(1, Int(contentRect.width / cellSize.width))
    }

    private var gridRows: Int {
        guard cellSize.height > 0 else { return 1 }
        return max(1, Int(contentRect.height / cellSize.height))
    }

    private func clampedGridCoordinate(for point: CGPoint) -> (row: Int, col: Int) {
        guard cellSize.width > 0, cellSize.height > 0 else { return (0, 0) }
        let localX = point.x - contentRect.minX
        let localY = point.y - contentRect.minY
        let col = max(0, min(Int(localX / cellSize.width), gridColumns - 1))
        let row = max(0, min(Int(localY / cellSize.height), gridRows - 1))
        return (row, col)
    }

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
        let originX = contentRect.minX
        let originY = contentRect.minY
        switch handle {
        case .start:
            // Top-left of the start cell, handle sits above the selection.
            let x = originX + CGFloat(sel.startCol) * cellSize.width
            let y = originY + CGFloat(sel.startRow) * cellSize.height
            return CGPoint(x: x, y: y - handleStemHeight - handleRadius)
        case .end:
            // Bottom-right of the end cell, handle sits below the selection.
            let x = originX + CGFloat(sel.endCol + 1) * cellSize.width
            let y = originY + CGFloat(sel.endRow + 1) * cellSize.height
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
                endCol = gridColumns - 1
            } else if row == selection.endRow {
                startCol = 0
                endCol = selection.endCol
            } else {
                startCol = 0
                endCol = gridColumns - 1
            }

            let rect = CGRect(
                x: contentRect.minX + CGFloat(startCol) * cellSize.width,
                y: contentRect.minY + CGFloat(row) * cellSize.height,
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
            let anchorX = contentRect.minX + CGFloat(selection.startCol) * cellSize.width
            let anchorY = contentRect.minY + CGFloat(selection.startRow) * cellSize.height
            ctx.move(to: CGPoint(x: anchorX, y: anchorY))
            ctx.addLine(to: CGPoint(x: center.x, y: center.y + handleRadius))
            ctx.strokePath()
        case .end:
            // Stem from bottom-right of end cell up to circle.
            let anchorX = contentRect.minX + CGFloat(selection.endCol + 1) * cellSize.width
            let anchorY = contentRect.minY + CGFloat(selection.endRow + 1) * cellSize.height
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
        let coord = clampedGridCoordinate(for: point)
        let row = coord.row
        let col = coord.col

        switch gesture.state {
        case .began:
            let startCenter = handleCenter(for: sel, handle: .start)
            let endCenter = handleCenter(for: sel, handle: .end)
            let distStart = hypot(point.x - startCenter.x, point.y - startCenter.y)
            let distEnd = hypot(point.x - endCenter.x, point.y - endCenter.y)
            activeHandle = distStart < distEnd ? .start : .end
            lastDragRow = row
            lastDragCol = col
            feedbackGenerator.prepare()

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
            selection = sel
            onSelectionChanged?(sel)
            // Only fire haptic when the selection moves to a different cell.
            if row != lastDragRow || col != lastDragCol {
                lastDragRow = row
                lastDragCol = col
                feedbackGenerator.impactOccurred(intensity: 0.5)
            }

        case .ended, .cancelled, .failed:
            activeHandle = nil
            lastDragRow = -1
            lastDragCol = -1

            // Show copy menu after handle drag finishes.
            if gesture.state == .ended, let sel = selection?.normalized {
                let midRow = (sel.startRow + sel.endRow) / 2
                let centerX = contentRect.minX + CGFloat(sel.startCol + sel.endCol + 1) / 2.0 * cellSize.width
                let centerY = contentRect.minY + CGFloat(midRow) * cellSize.height + cellSize.height / 2.0
                onShowMenu?(CGPoint(x: centerX, y: centerY))
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
