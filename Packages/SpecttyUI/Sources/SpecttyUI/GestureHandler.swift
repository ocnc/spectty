import UIKit
import SpecttyTerminal

/// Handles gestures on the terminal view: scroll, pinch-to-zoom, selection.
@MainActor
public final class GestureHandler: NSObject {
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

    private var panGesture: UIPanGestureRecognizer?
    private var pinchGesture: UIPinchGestureRecognizer?
    private var longPressGesture: UILongPressGestureRecognizer?
    private var twoFingerTapGesture: UITapGestureRecognizer?

    private var initialFontSize: CGFloat = 14
    private var currentSelectionStart: (row: Int, col: Int)?
    private var currentSelection: TerminalSelection?
    private let selectionFeedback = UIImpactFeedbackGenerator(style: .light)

    public init(metalView: TerminalMetalView, emulator: any TerminalEmulator) {
        self.metalView = metalView
        self.emulator = emulator
        super.init()
        setupGestures()
    }

    private func setupGestures() {
        guard let metalView = metalView else { return }

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
    }

    // MARK: - Pan (Scroll)

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let metalView = metalView, let emulator = emulator else { return }

        let translation = gesture.translation(in: metalView)
        let cellHeight = metalView.cellSize.height

        // Check if alternate screen (tmux/vim) — send mouse scroll events instead.
        if emulator.state.modes.contains(.alternateScreen) && emulator.state.modes.contains(.mouseAny) {
            // In alternate screen with mouse tracking, send scroll events.
            if gesture.state == .changed {
                let lines = Int(translation.y / cellHeight)
                if lines != 0 {
                    // Send mouse scroll button events.
                    let button: UInt8 = lines > 0 ? 64 : 65 // Up or Down scroll
                    let count = abs(lines)
                    for _ in 0..<count {
                        if emulator.state.modes.contains(.mouseSGR) {
                            let data = Data("\u{1B}[<\(button);1;1M".utf8)
                            onMouseEvent?(data)
                        }
                    }
                    gesture.setTranslation(.zero, in: metalView)
                }
            }
            return
        }

        // Normal screen: scroll through scrollback buffer.
        if gesture.state == .changed {
            let lines = Int(translation.y / cellHeight)
            if lines != 0 {
                metalView.scrollBy(lines)
                gesture.setTranslation(.zero, in: metalView)
            }
        }
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
        let cellSize = metalView.cellSize
        let grid = metalView.gridSize
        let col = max(0, min(Int(point.x / cellSize.width), grid.columns - 1))
        let row = max(0, min(Int(point.y / cellSize.height), grid.rows - 1))

        switch gesture.state {
        case .began:
            metalView.becomeFirstResponder()
            selectionFeedback.prepare()
            selectionFeedback.impactOccurred()
            currentSelectionStart = (row: row, col: col)
            let sel = TerminalSelection(startRow: row, startCol: col, endRow: row, endCol: col)
            currentSelection = sel
            onSelectionChanged?(sel)

        case .changed:
            guard let start = currentSelectionStart else { return }
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
        let cellSize = metalView.cellSize
        let norm = sel.normalized

        let midRow = (norm.startRow + norm.endRow) / 2
        let centerX = CGFloat(norm.startCol + norm.endCol + 1) / 2.0 * cellSize.width
        let centerY = CGFloat(midRow) * cellSize.height + cellSize.height / 2.0
        onShowMenu?(CGPoint(x: centerX, y: centerY))
    }

    /// Update the tracked selection (e.g. when handles are dragged externally).
    public func updateSelection(_ selection: TerminalSelection?) {
        currentSelection = selection
    }

    // MARK: - Two-Finger Tap (Paste)

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard let pasteboard = UIPasteboard.general.string else { return }

        guard let emulator = emulator else { return }

        var pasteData: Data
        if emulator.state.modes.contains(.bracketedPaste) {
            let bracketed = "\u{1B}[200~" + pasteboard + "\u{1B}[201~"
            pasteData = Data(bracketed.utf8)
        } else {
            pasteData = Data(pasteboard.utf8)
        }

        onMouseEvent?(pasteData)
    }
}
