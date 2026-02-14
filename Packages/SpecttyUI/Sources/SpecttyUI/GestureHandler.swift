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

    private var panGesture: UIPanGestureRecognizer?
    private var pinchGesture: UIPinchGestureRecognizer?
    private var longPressGesture: UILongPressGestureRecognizer?
    private var twoFingerTapGesture: UITapGestureRecognizer?

    private var initialFontSize: CGFloat = 14

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
        let cellHeight = metalView.terminalFont.size * 1.2 // approximate

        // Check if alternate screen (tmux/vim) — send mouse scroll events instead.
        if emulator.state.modes.contains(.alternateScreen) && emulator.state.modes.contains(.mouseAny) {
            // In alternate screen with mouse tracking, send scroll events.
            if gesture.state == .changed {
                let lines = Int(-translation.y / cellHeight)
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
            let lines = Int(-translation.y / cellHeight)
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
        // TODO: Implement text selection with drag handles.
        // Phase 2 feature — for now, just show the UIMenuController for copy.
        guard let metalView = metalView else { return }

        if gesture.state == .began {
            metalView.becomeFirstResponder()
            let menu = UIMenuController.shared
            menu.showMenu(from: metalView, rect: CGRect(origin: gesture.location(in: metalView), size: .zero))
        }
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
