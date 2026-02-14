import UIKit
import MetalKit
import SpecttyTerminal

/// MTKView subclass that renders the terminal using Metal.
/// Conforms to UIKeyInput so iOS presents the software keyboard.
public final class TerminalMetalView: MTKView, UIKeyInput {
    private var renderer: TerminalMetalRenderer?
    private weak var terminalEmulator: (any TerminalEmulator)?
    private var scrollOffset: Int = 0
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    private lazy var _inputAccessory: TerminalInputAccessory = {
        let bar = TerminalInputAccessory(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 44))
        bar.autoresizingMask = .flexibleWidth
        bar.onKeyPress = { [weak self] event in
            self?.feedbackGenerator.impactOccurred()
            self?.onKeyInput?(event)
        }
        return bar
    }()

    /// Callback for when the view is resized and a new grid size is computed.
    public var onResize: ((Int, Int) -> Void)?

    /// Callback for key input.
    public var onKeyInput: ((KeyEvent) -> Void)?

    /// Callback for paste data (bracketed paste aware).
    public var onPaste: ((Data) -> Void)?

    /// Current font configuration.
    public private(set) var terminalFont = TerminalFont()

    /// Gesture handler for scroll, pinch, selection.
    private var gestureHandler: GestureHandler?

    /// Last reported grid size — avoids duplicate and zero-size resize notifications.
    private var lastReportedGridSize: (columns: Int, rows: Int) = (0, 0)

    /// Debounce timer for resize — prevents sending intermediate sizes during keyboard animation.
    private var resizeDebounce: DispatchWorkItem?

    /// Visual bell flash layer.
    private var bellLayer: CALayer?

    public init(frame: CGRect, emulator: any TerminalEmulator) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        super.init(frame: frame, device: device)
        self.terminalEmulator = emulator
        self.renderer = TerminalMetalRenderer(device: device, scaleFactor: UIScreen.main.scale)
        feedbackGenerator.prepare()
        configure()
        setupGestureHandler(emulator: emulator)
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
        self.isUserInteractionEnabled = true

        // Tap to focus and show keyboard.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        if isFirstResponder {
            resignFirstResponder()
        } else {
            becomeFirstResponder()
        }
    }

    private func setupGestureHandler(emulator: any TerminalEmulator) {
        let handler = GestureHandler(metalView: self, emulator: emulator)
        handler.onMouseEvent = { [weak self] data in
            self?.onPaste?(data)
        }
        self.gestureHandler = handler
    }

    // MARK: - First Responder + Software Keyboard

    public override var canBecomeFirstResponder: Bool { true }

    public override var inputAccessoryView: UIView? { _inputAccessory }

    /// UIKeyInput: tells iOS we always accept text (keeps keyboard open).
    public var hasText: Bool { true }

    /// UIKeyInput: software keyboard character input.
    public func insertText(_ text: String) {
        var modifiers = KeyModifiers()
        if _inputAccessory.ctrlActive { modifiers.insert(.control) }
        if _inputAccessory.shiftActive { modifiers.insert(.shift) }
        let hasModifiers = !modifiers.isEmpty

        for char in text {
            let characters: String
            if char == "\n" {
                characters = "\r"
            } else if modifiers.contains(.control), let ascii = char.asciiValue,
                      (0x61...0x7A).contains(ascii) || (0x41...0x5A).contains(ascii) {
                // Ctrl+letter → control character (e.g., Ctrl+C = 0x03)
                let upper = ascii & 0x1F
                characters = String(UnicodeScalar(upper))
            } else {
                characters = String(char)
            }

            let event = KeyEvent(
                keyCode: char == "\n" ? 0x28 : 0,
                modifiers: modifiers,
                isKeyDown: true,
                characters: characters
            )
            onKeyInput?(event)
        }

        if hasModifiers {
            _inputAccessory.deactivateModifiers()
        }
    }

    /// UIKeyInput: software keyboard backspace.
    public func deleteBackward() {
        var modifiers = KeyModifiers()
        if _inputAccessory.ctrlActive { modifiers.insert(.control) }
        if _inputAccessory.shiftActive { modifiers.insert(.shift) }
        let hasModifiers = !modifiers.isEmpty

        let event = KeyEvent(
            keyCode: 0x2A,
            modifiers: modifiers,
            isKeyDown: true,
            characters: "\u{7F}"
        )
        onKeyInput?(event)

        if hasModifiers {
            _inputAccessory.deactivateModifiers()
        }
    }

    /// Disable autocorrect/autocapitalize — raw terminal input.
    public var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    public var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    public var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    public var smartDashesType: UITextSmartDashesType {
        get { .no }
        set {}
    }

    public var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set {}
    }

    public var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    public var keyboardType: UIKeyboardType {
        get { .asciiCapable }
        set {}
    }

    // MARK: - External Keyboard Shortcuts

    public override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(handlePaste)),
            UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(handleClearScreen)),
            UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(handleCopy)),
        ]
    }

    @objc private func handlePaste() {
        guard let text = UIPasteboard.general.string else { return }
        if let emulator = terminalEmulator, emulator.state.modes.contains(.bracketedPaste) {
            let bracketed = "\u{1B}[200~" + text + "\u{1B}[201~"
            onPaste?(Data(bracketed.utf8))
        } else {
            onPaste?(Data(text.utf8))
        }
    }

    @objc private func handleClearScreen() {
        // Send Ctrl+L (form feed — clears screen in most shells).
        let event = KeyEvent(keyCode: 0, modifiers: .control, isKeyDown: true, characters: "l")
        onKeyInput?(event)
    }

    @objc private func handleCopy() {
        // TODO: Copy selected text when selection is implemented.
        // For now this is a no-op to prevent the default Cmd+C behavior.
    }

    // MARK: - Visual Bell

    public func flashBell() {
        if bellLayer == nil {
            let flash = CALayer()
            flash.backgroundColor = UIColor.white.withAlphaComponent(0.15).cgColor
            flash.frame = bounds
            flash.opacity = 0
            layer.addSublayer(flash)
            bellLayer = flash
        }

        guard let flash = bellLayer else { return }
        flash.frame = bounds

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.0, 1.0, 0.0]
        anim.keyTimes = [0, 0.1, 1.0]
        anim.duration = 0.15
        flash.add(anim, forKey: "bell")

        feedbackGenerator.impactOccurred(intensity: 0.5)
    }

    // MARK: - Appearance

    public func setFont(_ font: TerminalFont) {
        guard font.name != terminalFont.name || font.size != terminalFont.size else { return }
        self.terminalFont = font
        renderer?.setFont(font)
        notifyResizeIfNeeded()
    }

    public func setTheme(_ theme: TerminalTheme) {
        renderer?.setTheme(theme)
        // Update the clear color to match the theme background.
        self.clearColor = MTLClearColor(
            red: Double(theme.background.0) / 255.0,
            green: Double(theme.background.1) / 255.0,
            blue: Double(theme.background.2) / 255.0,
            alpha: 1.0
        )
    }

    public func setCursorStyle(_ style: CursorStyle) {
        renderer?.setCursorStyle(style)
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

    /// The size of a single terminal cell in points.
    public var cellSize: CGSize {
        renderer?.cellSize ?? CGSize(width: 8, height: 17)
    }

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
        // Don't send resize for views that haven't been laid out yet.
        guard columns > 1, rows > 1 else { return }
        // Don't send duplicate resizes.
        guard columns != lastReportedGridSize.columns || rows != lastReportedGridSize.rows else { return }

        // Debounce: keyboard animations trigger many intermediate layouts.
        // Only send the resize once the layout stabilizes.
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let (cols, rows) = self.gridSize
            guard cols > 1, rows > 1 else { return }
            guard cols != self.lastReportedGridSize.columns || rows != self.lastReportedGridSize.rows else { return }
            self.lastReportedGridSize = (cols, rows)
            self.onResize?(cols, rows)
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        bellLayer?.frame = bounds
        notifyResizeIfNeeded()
    }

    // MARK: - Hardware Key Input (external keyboards)

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
