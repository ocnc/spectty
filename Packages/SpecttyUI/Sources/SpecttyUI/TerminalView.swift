import SwiftUI
import SpecttyTerminal

/// SwiftUI wrapper for the Metal terminal view.
public struct TerminalView: UIViewRepresentable {
    private let emulator: any TerminalEmulator
    private let onKeyInput: ((KeyEvent) -> Void)?
    private let onPaste: ((Data) -> Void)?
    private let onResize: ((Int, Int) -> Void)?

    public init(
        emulator: any TerminalEmulator,
        onKeyInput: ((KeyEvent) -> Void)? = nil,
        onPaste: ((Data) -> Void)? = nil,
        onResize: ((Int, Int) -> Void)? = nil
    ) {
        self.emulator = emulator
        self.onKeyInput = onKeyInput
        self.onPaste = onPaste
        self.onResize = onResize
    }

    public func makeUIView(context: Context) -> TerminalMetalView {
        let metalView = TerminalMetalView(frame: .zero, emulator: emulator)
        metalView.onKeyInput = onKeyInput
        metalView.onPaste = onPaste
        metalView.onResize = onResize

        // Auto-focus once on creation to show the keyboard.
        DispatchQueue.main.async {
            metalView.becomeFirstResponder()
        }

        return metalView
    }

    public func updateUIView(_ uiView: TerminalMetalView, context: Context) {
        uiView.onKeyInput = onKeyInput
        uiView.onPaste = onPaste
        uiView.onResize = onResize
    }
}
