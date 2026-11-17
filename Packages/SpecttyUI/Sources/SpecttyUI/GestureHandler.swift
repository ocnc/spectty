import UIKit
import SpecttyTerminal

/// Describes an edge-swipe gesture for session switching.
public struct EdgeSwipeEvent {
    public enum Direction { case left, right }
    public enum Phase { case began, changed, ended, cancelled }

    public let direction: Direction
    public let phase: Phase
    public let translation: CGFloat
    public let velocity: CGFloat
}

/// Handles gestures on the terminal view: scroll, pinch-to-zoom, selection.
@MainActor
public final class GestureHandler: NSObject, UIGestureRecognizerDelegate {
    private weak var metalView: TerminalMetalView?
    private weak var emulator: (any TerminalEmulator)?

    /// Callback for font size changes from pinch-to-zoom.
    public var onFontSizeChange: ((CGFloat) -> Void)?

    /// Callback to send mouse events to the transport.
    public var onMouseEvent: ((Data) -> Void)?

    /// Callback for text selection changes (nil = selection cleared).
    public var onSelectionChanged: ((TerminalSelection?) -> Void)?

    /// Callback to request the edit menu (copy/paste) at a given point.
    public var onShowMenu: ((CGPoint) -> Void)?

    /// Callback for edge-swipe gestures (session switching).
    public var onEdgeSwipe: ((EdgeSwipeEvent) -> Void)?

    /// Callback for local tap fallback when remote mouse handling is inactive.
    public var onLocalTap: (() -> Void)?

    private var tapGesture: UITapGestureRecognizer?
    private var panGesture: UIPanGestureRecognizer?
    private var leftEdgeGesture: UIScreenEdgePanGestureRecognizer?
    private var rightEdgeGesture: UIScreenEdgePanGestureRecognizer?
    private var pinchGesture: UIPinchGestureRecognizer?
    private var longPressGesture: UILongPressGestureRecognizer?
    private var twoFingerTapGesture: UITapGestureRecognizer?

    private var initialFontSize: CGFloat = 14
    private var currentSelectionStart: (row: Int, col: Int)?
    private var currentSelection: TerminalSelection?
    /// Where the current scroll drag first touched the terminal.
    private var dragStart: CGPoint?
    private let selectionFeedback = UIImpactFeedbackGenerator(style: .light)

    public init(metalView: TerminalMetalView, emulator: any TerminalEmulator) {
        self.metalView = metalView
        self.emulator = emulator
        super.init()
        setupGestures()
    }

    /// Remove all gesture recognizers from the metal view.
    public func removeGestures() {
        guard let metalView = metalView else { return }
        [tapGesture, panGesture, pinchGesture, longPressGesture, twoFingerTapGesture].compactMap { $0 }.forEach {
            metalView.removeGestureRecognizer($0)
        }
        [leftEdgeGesture, rightEdgeGesture].compactMap { $0 }.forEach {
            metalView.removeGestureRecognizer($0)
        }
    }

    private func setupGestures() {
        guard let metalView = metalView else { return }

        // Single tap for remote mouse click or local focus fallback.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTouchesRequired = 1
        metalView.addGestureRecognizer(tap)
        self.tapGesture = tap

        // Pan for scrollback.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        metalView.addGestureRecognizer(pan)
        self.panGesture = pan

        // Pinch to zoom (font size).
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        metalView.addGestureRecognizer(pinch)
        self.pinchGesture = pinch

        // Long press for text selection.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        metalView.addGestureRecognizer(longPress)
        self.longPressGesture = longPress

        // Two-finger tap to paste.
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        metalView.addGestureRecognizer(twoFingerTap)
        self.twoFingerTapGesture = twoFingerTap

        // Edge swipe for session switching.
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        leftEdge.edges = .left
        metalView.addGestureRecognizer(leftEdge)
        self.leftEdgeGesture = leftEdge

        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        rightEdge.edges = .right
        metalView.addGestureRecognizer(rightEdge)
        self.rightEdgeGesture = rightEdge

        // Scroll pan defers to edge pans near the edges.
        pan.require(toFail: leftEdge)
        pan.require(toFail: rightEdge)

        // Single-finger tap should not interfere with the two-finger paste gesture.
        tap.require(toFail: twoFingerTap)
        for gesture in [tap, pan, pinch, longPress, twoFingerTap, leftEdge, rightEdge] {
            gesture.delegate = self
        }
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl || current is TerminalInputAccessory { return false }
            view = current.superview
        }
        return true
    }

    // MARK: - Tap (Remote Mouse / Local Focus)

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard let metalView else { return }
        handleTap(at: gesture.location(in: metalView))
    }

    func handleTap(at point: CGPoint) {
        guard let metalView, let emulator else { return }
        let modes = emulator.state.modes
        guard metalView.terminalContentRect.contains(point) else { return }
        if metalView.isShowingLiveScreen,
           modes.contains(.mouseSGR),
           modes.contains(.mouseButton) || modes.contains(.mouseAny) {
            let (x, y) = mouseCell(at: point, in: metalView, emulator: emulator)
            // Keep the click atomic in the existing outbound queue.
            onMouseEvent?(Data("\u{1B}[<0;\(x);\(y)M\u{1B}[<0;\(x);\(y)m".utf8))
            metalView.becomeFirstResponder()
            return
        }
        if metalView.openLink(at: point) { return }
        onLocalTap?()
    }

    // MARK: - Pan (Scroll)

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let metalView else { return }
        let location = gesture.location(in: metalView)
        let translation = gesture.translation(in: metalView)
        if handleDrag(gesture.state, at: location, translation: translation) {
            gesture.setTranslation(.zero, in: metalView)
        }
    }

    /// Scrolls by the whole lines of a one-finger drag. Returns true when it used the
    /// translation, which the caller then resets.
    func handleDrag(_ state: UIGestureRecognizer.State, at location: CGPoint, translation: CGPoint) -> Bool {
        guard let metalView, let emulator else { return false }
        switch state {
        case .began:
            // UIKit recognizes a pan after the finger has moved; keep where it first touched.
            dragStart = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            return false
        case .changed:
            break
        default:
            dragStart = nil
            return false
        }

        let lines = Int(translation.y / metalView.cellSize.height)
        guard lines != 0 else { return false }

        // Check if alternate screen (tmux/vim) — send mouse scroll events instead.
        let modes = emulator.state.modes
        if modes.contains(.alternateScreen) && modes.contains(.mouseAny) {
            if modes.contains(.mouseSGR) {
                // Report the wheel where the drag started: programs scroll what is under the pointer.
                let (x, y) = mouseCell(at: dragStart ?? location, in: metalView, emulator: emulator)
                let button = lines > 0 ? 64 : 65 // Up or Down scroll
                let report = Data("\u{1B}[<\(button);\(x);\(y)M".utf8)
                for _ in 0..<abs(lines) {
                    onMouseEvent?(report)
                }
            }
            return true
        }

        // Normal screen: scroll through scrollback buffer.
        metalView.scrollBy(lines)
        return true
    }

    /// The 1-based cell under a point, as mouse reports address it.
    private func mouseCell(at point: CGPoint, in metalView: TerminalMetalView, emulator: any TerminalEmulator) -> (x: Int, y: Int) {
        let coord = metalView.gridCoordinate(for: point)
        let state = emulator.state
        return (min(coord.col + 1, state.columns), min(coord.row + 1, state.rows))
    }

    // MARK: - Pinch to Zoom

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let metalView = metalView else { return }

        switch gesture.state {
        case .began:
            initialFontSize = metalView.terminalFont.size
        case .changed:
            let newSize = max(8, min(initialFontSize * gesture.scale, 32))
            onFontSizeChange?(newSize)
        default:
            break
        }
    }

    // MARK: - Long Press (Selection)

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let metalView = metalView else { return }

        let point = gesture.location(in: metalView)
        let coord = metalView.gridCoordinate(for: point)
        let row = coord.row
        var col = coord.col
        let lines = metalView.visibleLines
        if col > 0, lines.indices.contains(row),
           col < lines[row].cells.count, lines[row].cells[col].isWideTail {
            col -= 1
        }

        switch gesture.state {
        case .began:
            metalView.becomeFirstResponder()
            selectionFeedback.prepare()
            selectionFeedback.impactOccurred()
            currentSelectionStart = (row: row, col: col)
            let sel = TerminalText.link(atRow: row, col: col, in: lines)?.selection
                ?? TerminalSelection(startRow: row, startCol: col, endRow: row, endCol: col)
            currentSelection = sel
            onSelectionChanged?(sel)

        case .changed:
            guard let start = currentSelectionStart else { return }
            guard row != start.row || col != start.col else { return }
            let sel = TerminalSelection(
                startRow: start.row,
                startCol: start.col,
                endRow: row,
                endCol: col
            )
            currentSelection = sel
            onSelectionChanged?(sel)

        case .ended:
            currentSelectionStart = nil
            // Show copy menu centered on the selection.
            requestMenu()

        case .cancelled, .failed:
            currentSelectionStart = nil
            currentSelection = nil
            onSelectionChanged?(nil)

        default:
            break
        }
    }

    /// Request the edit menu centered on the current selection.
    private func requestMenu() {
        guard let sel = currentSelection else { return }
        guard let metalView = metalView else { return }
        let norm = sel.normalized

        let midRow = (norm.startRow + norm.endRow) / 2
        onShowMenu?(metalView.selectionCenterPoint(row: midRow, startCol: norm.startCol, endCol: norm.endCol))
    }

    /// Update the tracked selection (e.g. when handles are dragged externally).
    public func updateSelection(_ selection: TerminalSelection?) {
        currentSelection = selection
    }

    // MARK: - Two-Finger Tap (Paste)

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        metalView?.paste(nil)
    }

    // MARK: - Edge Pan (Session Switching)

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let metalView = metalView else { return }

        let direction: EdgeSwipeEvent.Direction = gesture.edges == .left ? .left : .right
        let translation = gesture.translation(in: metalView).x
        let velocity = gesture.velocity(in: metalView).x

        let phase: EdgeSwipeEvent.Phase
        switch gesture.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: return
        }

        let event = EdgeSwipeEvent(
            direction: direction,
            phase: phase,
            translation: translation,
            velocity: velocity
        )
        onEdgeSwipe?(event)
    }
}
