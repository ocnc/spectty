import SwiftUI
import SpecttyTerminal

/// SwiftUI wrapper for the Metal terminal view.
///
/// Uses a Coordinator to hold callback closures so the underlying
/// TerminalMetalView's references stay stable across SwiftUI re-renders.
public struct TerminalView: UIViewRepresentable {
    private let emulator: any TerminalEmulator
    private let onKeyInput: ((KeyEvent) -> Void)?
    private let onPaste: ((Data) -> Void)?
    private let onResize: ((Int, Int) -> Void)?
    private let onEdgeSwipe: ((EdgeSwipeEvent) -> Void)?
    private let font: TerminalFont
    private let themeName: String
    private let cursorStyle: CursorStyle
    private let autoFocus: Bool

    public init(
        emulator: any TerminalEmulator,
        font: TerminalFont = TerminalFont(),
        themeName: String = "Default",
        cursorStyle: CursorStyle = .block,
        autoFocus: Bool = true,
        onKeyInput: ((KeyEvent) -> Void)? = nil,
        onPaste: ((Data) -> Void)? = nil,
        onResize: ((Int, Int) -> Void)? = nil,
        onEdgeSwipe: ((EdgeSwipeEvent) -> Void)? = nil
    ) {
        self.emulator = emulator
        self.font = font
        self.themeName = themeName
        self.cursorStyle = cursorStyle
        self.autoFocus = autoFocus
        self.onKeyInput = onKeyInput
        self.onPaste = onPaste
        self.onResize = onResize
        self.onEdgeSwipe = onEdgeSwipe
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> TerminalMetalView {
        let coordinator = context.coordinator
        coordinator.onKeyInput = onKeyInput
        coordinator.onPaste = onPaste
        coordinator.onResize = onResize
        coordinator.onEdgeSwipe = onEdgeSwipe
        coordinator.emulatorID = ObjectIdentifier(emulator)

        let metalView = TerminalMetalView(frame: .zero, emulator: emulator)
        metalView.onKeyInput = { [weak coordinator] event in
            coordinator?.onKeyInput?(event)
        }
        metalView.onPaste = { [weak coordinator] data in
            coordinator?.onPaste?(data)
        }
        metalView.onResize = { [weak coordinator] cols, rows in
            coordinator?.onResize?(cols, rows)
        }
        metalView.onEdgeSwipe = { [weak coordinator] event in
            coordinator?.onEdgeSwipe?(event)
        }
        metalView.setFont(font)
        metalView.setTheme(TerminalTheme.named(themeName))
        metalView.setCursorStyle(cursorStyle)

        // Auto-focus once on creation to show the keyboard.
        if autoFocus {
            DispatchQueue.main.async {
                metalView.becomeFirstResponder()
            }
        }

        return metalView
    }

    public func updateUIView(_ uiView: TerminalMetalView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onKeyInput = onKeyInput
        coordinator.onPaste = onPaste
        coordinator.onResize = onResize
        coordinator.onEdgeSwipe = onEdgeSwipe

        // Swap emulator in-place if it changed (e.g. carousel session switch).
        let newID = ObjectIdentifier(emulator)
        if coordinator.emulatorID != newID {
            coordinator.emulatorID = newID
            uiView.setEmulator(emulator)
        }

        uiView.setFont(font)
        uiView.setTheme(TerminalTheme.named(themeName))
        uiView.setCursorStyle(cursorStyle)
    }

    public final class Coordinator {
        var onKeyInput: ((KeyEvent) -> Void)?
        var onPaste: ((Data) -> Void)?
        var onResize: ((Int, Int) -> Void)?
        var onEdgeSwipe: ((EdgeSwipeEvent) -> Void)?
        var emulatorID: ObjectIdentifier?
    }
}
