import SwiftUI
import SpecttyTerminal

/// SwiftUI wrapper for the Metal terminal view.
public struct TerminalView: UIViewRepresentable {
    private let emulator: any TerminalEmulator
    private let onKeyInput: ((KeyEvent) -> Void)?
    private let onResize: ((Int, Int) -> Void)?

    public init(
        emulator: any TerminalEmulator,
        onKeyInput: ((KeyEvent) -> Void)? = nil,
        onResize: ((Int, Int) -> Void)? = nil
    ) {
        self.emulator = emulator
        self.onKeyInput = onKeyInput
        self.onResize = onResize
    }

    public func makeUIView(context: Context) -> TerminalMetalView {
        let metalView = TerminalMetalView(frame: .zero, emulator: emulator)
        metalView.onKeyInput = onKeyInput
        metalView.onResize = onResize
        return metalView
    }

    public func updateUIView(_ uiView: TerminalMetalView, context: Context) {
        uiView.onKeyInput = onKeyInput
        uiView.onResize = onResize
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        // Future: gesture state, selection state, etc.
    }
}
