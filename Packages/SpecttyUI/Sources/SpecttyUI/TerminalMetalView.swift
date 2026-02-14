import UIKit
import MetalKit
import SpecttyTerminal

/// MTKView subclass that renders the terminal using Metal.
public final class TerminalMetalView: MTKView {
    private var renderer: TerminalMetalRenderer?
    private weak var terminalEmulator: (any TerminalEmulator)?
    private var scrollOffset: Int = 0

    /// Callback for when the view is resized and a new grid size is computed.
    public var onResize: ((Int, Int) -> Void)?

    /// Callback for key input.
    public var onKeyInput: ((KeyEvent) -> Void)?

    /// Current font configuration.
    public private(set) var terminalFont = TerminalFont()

    public init(frame: CGRect, emulator: any TerminalEmulator) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        super.init(frame: frame, device: device)
        self.terminalEmulator = emulator
        self.renderer = TerminalMetalRenderer(device: device)
        configure()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1.0)
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 60
        self.delegate = self
        self.isMultipleTouchEnabled = true

        // Allow the view to become first responder for key input.
        self.isUserInteractionEnabled = true
    }

    // MARK: - Font

    public func setFont(_ font: TerminalFont) {
        self.terminalFont = font
        renderer?.setFont(font)
        notifyResizeIfNeeded()
    }

    // MARK: - Scrollback

    public func scrollBy(_ lines: Int) {
        guard let emulator = terminalEmulator else { return }
        let maxScroll = emulator.scrollbackCount
        scrollOffset = max(0, min(scrollOffset + lines, maxScroll))
        setNeedsDisplay()
    }

    public func scrollToBottom() {
        scrollOffset = 0
        setNeedsDisplay()
    }

    // MARK: - Grid Size

    public var gridSize: (columns: Int, rows: Int) {
        guard let renderer = renderer else { return (80, 24) }
        let cellSize = renderer.cellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return (80, 24) }
        let columns = max(1, Int(bounds.width / cellSize.width))
        let rows = max(1, Int(bounds.height / cellSize.height))
        return (columns, rows)
    }

    private func notifyResizeIfNeeded() {
        let (columns, rows) = gridSize
        onResize?(columns, rows)
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        notifyResizeIfNeeded()
    }

    // MARK: - Key Input

    public override var canBecomeFirstResponder: Bool { true }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let keyEvent = KeyEvent(
                keyCode: UInt32(key.keyCode.rawValue),
                modifiers: modifiersFromUIKey(key),
                isKeyDown: true,
                characters: key.characters ?? ""
            )
            onKeyInput?(keyEvent)
        }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Key up events — usually not needed for terminal, but pass through.
        for press in presses {
            guard let key = press.key else { continue }
            let keyEvent = KeyEvent(
                keyCode: UInt32(key.keyCode.rawValue),
                modifiers: modifiersFromUIKey(key),
                isKeyDown: false,
                characters: key.characters ?? ""
            )
            onKeyInput?(keyEvent)
        }
    }

    private func modifiersFromUIKey(_ key: UIKey) -> KeyModifiers {
        var mods = KeyModifiers()
        if key.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if key.modifierFlags.contains(.alternate) { mods.insert(.alt) }
        if key.modifierFlags.contains(.control) { mods.insert(.control) }
        if key.modifierFlags.contains(.command) { mods.insert(.super) }
        return mods
    }
}

// MARK: - MTKViewDelegate

extension TerminalMetalView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        notifyResizeIfNeeded()
    }

    public func draw(in view: MTKView) {
        guard let emulator = terminalEmulator,
              let renderer = renderer,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable
        else { return }

        let state = emulator.state.activeScreen
        renderer.update(state: state, scrollback: emulator.state.scrollback, scrollOffset: scrollOffset)
        renderer.render(to: renderPassDescriptor, drawable: drawable)
    }
}
