import UIKit
import MetalKit
import SpecttyTerminal

// UIKit owns marked text; only committed text leaves this field.
final class TerminalIMETextField: UITextField {
    var accessoryProvider: (() -> UIView?)?
    var emptyDeleteHandler: (() -> Void)?
    var routePresses: ((Set<UIPress>, UIPressesEvent?, Bool) -> Set<UIPress>)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?

    override var inputAccessoryView: UIView? {
        get { accessoryProvider?() }
        set {}
    }

    override func deleteBackward() {
        let wasEmpty = markedTextRange == nil && (text?.isEmpty ?? true)
        super.deleteBackward()
        if wasEmpty { emptyDeleteHandler?() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = routePresses?(presses, event, true) ?? presses
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = routePresses?(presses, event, false) ?? presses
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = routePresses?(presses, event, false) ?? presses
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }

    override func paste(_ sender: Any?) { onPaste?() }
    override func copy(_ sender: Any?) { onCopy?() }
}

/// MTKView subclass that renders the terminal using Metal.
/// Conforms to UIKeyInput so iOS presents the software keyboard.
public final class TerminalMetalView: MTKView, UIKeyInput {
    let imeTextField = TerminalIMETextField(frame: .zero)
    let preeditLabel = UILabel()
    private var isClearingIME = false
    private var compositionReturnHeld = false
    private var inputEnabled = true
    private var wantsFirstResponder = false
    private var currentTheme: TerminalTheme = .default
    private var renderer: TerminalMetalRenderer?
    private weak var terminalEmulator: (any TerminalEmulator)?
    private var scrollOffset: Int = 0
    var isShowingLiveScreen: Bool { inputEnabled && scrollOffset == 0 && selectionView.selection == nil }
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    private lazy var _inputAccessory: TerminalInputAccessory = {
        let bar = TerminalInputAccessory(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 44))
        bar.autoresizingMask = .flexibleWidth
        bar.onKeyPress = { [weak self] event in
            guard let self, self.inputEnabled else { return }
            self.feedbackGenerator.impactOccurred()
            if event.keyCode == 0x29, self.imeTextField.markedTextRange != nil {
                self.cancelIMEComposition()
            } else {
                self.onKeyInput?(event)
            }
        }
        return bar
    }()
    private var pendingDisplayWorkItem: DispatchWorkItem?
    private var isInBackground = false
    private var lastDisplayTime: CFTimeInterval = 0

    /// Callback for when the view is resized and a new grid size is computed.
    public var onResize: ((Int, Int) -> Void)?

    /// Callback for key input.
    public var onKeyInput: ((KeyEvent) -> Void)?

    /// Callback for paste data (bracketed paste aware).
    public var onPaste: ((Data) -> Void)?

    /// Callback for edge-swipe gestures (session switching).
    public var onEdgeSwipe: ((EdgeSwipeEvent) -> Void)?

    /// Current font configuration.
    public private(set) var terminalFont = TerminalFont()

    /// Built-in text gutter so terminal glyphs do not touch view edges.
    private let terminalContentInsets = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

    /// Gesture handler for scroll, pinch, selection.
    private var gestureHandler: GestureHandler?

    /// Last reported grid size — avoids duplicate and zero-size resize notifications.
    private var lastReportedGridSize: (columns: Int, rows: Int) = (0, 0)

    /// Debounce timer for resize — prevents sending intermediate sizes during keyboard animation.
    private var resizeDebounce: DispatchWorkItem?

    /// Text selection overlay.
    private let selectionView = TextSelectionView()

    /// Edit menu interaction (replaces deprecated UIMenuController).
    private var editMenuInteraction: UIEditMenuInteraction?

    /// Visual bell flash layer.
    private var bellLayer: CALayer?
    private static let minimumDisplayInterval: CFTimeInterval = 1.0 / 60

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
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.delegate = self
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true
        installDisplayChangeHandler(for: terminalEmulator)

        imeTextField.autocorrectionType = .no
        imeTextField.autocapitalizationType = .none
        imeTextField.smartQuotesType = .no
        imeTextField.smartDashesType = .no
        imeTextField.smartInsertDeleteType = .no
        imeTextField.spellCheckingType = .no
        imeTextField.keyboardType = .default
        imeTextField.delegate = self
        imeTextField.isAccessibilityElement = false
        imeTextField.textColor = .clear
        imeTextField.tintColor = .clear
        imeTextField.backgroundColor = .clear
        imeTextField.accessoryProvider = { [weak self] in self?._inputAccessory }
        imeTextField.emptyDeleteHandler = { [weak self] in self?.deleteBackward() }
        imeTextField.routePresses = { [weak self] presses, event, down in
            self?.routeHardwarePresses(presses, with: event, isKeyDown: down) ?? presses
        }
        imeTextField.onPaste = { [weak self] in self?.handlePaste() }
        imeTextField.onCopy = { [weak self] in self?.copyScreenText() }
        imeTextField.addTarget(self, action: #selector(handleIMETextChanged), for: .editingChanged)
        addSubview(imeTextField)
        preeditLabel.isUserInteractionEnabled = false
        preeditLabel.isHidden = true
        addSubview(preeditLabel)

        // Selection overlay — hit tests only near drag handles, passes through otherwise.
        selectionView.frame = bounds
        selectionView.contentInsets = terminalContentInsets
        selectionView.cellSize = cellSize
        addSubview(selectionView)

        // Edit menu interaction for copy/paste — nil delegate uses default
        // behavior, building the menu from canPerformAction/copy/paste.
        let interaction = UIEditMenuInteraction(delegate: nil)
        addInteraction(interaction)
        self.editMenuInteraction = interaction

        // Pause Metal rendering while backgrounded — drawables are unavailable
        // and attempting to render produces blank frames.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func appDidEnterBackground() {
        isInBackground = true
        pendingDisplayWorkItem?.cancel()
        pendingDisplayWorkItem = nil
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false
        requestDisplay()
    }

    private func handleLocalTap() {
        // Clear any active selection on tap before focusing the terminal.
        if selectionView.selection != nil {
            selectionView.selection = nil
            editMenuInteraction?.dismissMenu()
        }

        if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    /// Swap the terminal emulator without recreating the view.
    /// Preserves first-responder status (keyboard stays up).
    public func setEmulator(_ emulator: any TerminalEmulator) {
        cancelIMEComposition()
        terminalEmulator?.onDisplayChange = nil
        pendingDisplayWorkItem?.cancel()
        pendingDisplayWorkItem = nil
        self.terminalEmulator = emulator
        installDisplayChangeHandler(for: emulator)
        self.scrollOffset = 0
        gestureHandler?.removeGestures()
        setupGestureHandler(emulator: emulator)
        // Reset so the new emulator gets the current grid size.
        lastReportedGridSize = (0, 0)
        notifyResizeIfNeeded()
        requestDisplay()
    }

    private func installDisplayChangeHandler(for emulator: (any TerminalEmulator)?) {
        emulator?.onDisplayChange = { [weak self, weak emulator] in
            Task { @MainActor [weak self, weak emulator] in
                guard let self, let emulator, self.terminalEmulator === emulator else { return }
                self.requestDisplay()
            }
        }
    }

    private func requestDisplay() {
        guard window != nil, !isInBackground else { return }
        let now = CACurrentMediaTime()
        let nextDisplay = lastDisplayTime + Self.minimumDisplayInterval
        if now >= nextDisplay {
            pendingDisplayWorkItem?.cancel()
            pendingDisplayWorkItem = nil
            lastDisplayTime = now
            setNeedsDisplay()
            return
        }
        guard pendingDisplayWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDisplayWorkItem = nil
            guard self.window != nil, !self.isInBackground else { return }
            self.lastDisplayTime = CACurrentMediaTime()
            self.setNeedsDisplay()
        }
        pendingDisplayWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (nextDisplay - now), execute: work)
    }

    private func setupGestureHandler(emulator: any TerminalEmulator) {
        let handler = GestureHandler(metalView: self, emulator: emulator)
        handler.onMouseEvent = { [weak self] data in
            self?.onPaste?(data)
        }
        handler.onSelectionChanged = { [weak self] selection in
            guard let self else { return }
            self.selectionView.cellSize = self.cellSize
            self.selectionView.selection = selection
        }
        handler.onShowMenu = { [weak self] point in
            self?.presentEditMenu(at: point)
        }
        handler.onEdgeSwipe = { [weak self] event in
            self?.onEdgeSwipe?(event)
        }
        handler.onLocalTap = { [weak self] in
            self?.handleLocalTap()
        }
        // Handle-drag updates from the selection overlay.
        selectionView.onSelectionChanged = { [weak self, weak handler] selection in
            handler?.updateSelection(selection)
            self?.selectionView.cellSize = self?.cellSize ?? .zero
        }
        selectionView.onShowMenu = { [weak self] point in
            self?.presentEditMenu(at: point)
        }
        self.gestureHandler = handler
    }

    /// Present the edit menu at the given point in this view's coordinates.
    /// Deferred to the next run loop tick so UIKit finishes processing the
    /// gesture touch (avoids nil-window warnings and unsafeForcedSync).
    private func presentEditMenu(at point: CGPoint) {
        Task { @MainActor [weak self] in
            guard let self, self.selectionView.selection != nil else { return }
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
            self.editMenuInteraction?.presentEditMenu(with: config)
        }
    }

    // MARK: - First Responder + Software Keyboard

    public override var canBecomeFirstResponder: Bool { true }

    public override var inputAccessoryView: UIView? { _inputAccessory }

    public override var isFirstResponder: Bool { imeTextField.isFirstResponder }

    @discardableResult public override func becomeFirstResponder() -> Bool {
        wantsFirstResponder = true
        guard inputEnabled else { return false }
        updatePreeditOverlay()
        return imeTextField.becomeFirstResponder()
    }

    @discardableResult public override func resignFirstResponder() -> Bool {
        wantsFirstResponder = false
        cancelIMEComposition()
        return imeTextField.resignFirstResponder()
    }

    public func setInputEnabled(_ enabled: Bool) {
        guard inputEnabled != enabled else { return }
        inputEnabled = enabled
        if !enabled { cancelIMEComposition() }
        imeTextField.isEnabled = enabled
        if enabled && wantsFirstResponder { _ = becomeFirstResponder() }
    }

    func cancelIMEComposition() {
        isClearingIME = true
        imeTextField.text = ""
        imeTextField.unmarkText()
        compositionReturnHeld = false
        isClearingIME = false
        updatePreeditOverlay()
        requestDisplay()
    }

    @objc func handleIMETextChanged() {
        guard !isClearingIME else { return }
        guard inputEnabled else { cancelIMEComposition(); return }
        if imeTextField.markedTextRange == nil, let text = imeTextField.text, !text.isEmpty {
            imeTextField.text = ""
            insertText(text)
        }
        updatePreeditOverlay()
        requestDisplay()
    }

    private func updatePreeditOverlay() {
        guard let screen = terminalEmulator?.state.activeScreen else { return }
        let rect = terminalContentRect
        let col = max(0, min(screen.cursor.col, screen.columns - 1))
        let row = max(0, min(screen.cursor.row, screen.rows - 1))
        let origin = CGPoint(x: rect.minX + CGFloat(col) * cellSize.width,
                             y: rect.minY + CGFloat(row) * cellSize.height)
        let inputFrame = CGRect(origin: origin, size: cellSize)
        if imeTextField.frame != inputFrame { imeTextField.frame = inputFrame }
        let text = imeTextField.markedTextRange == nil ? "" : (imeTextField.text ?? "")
        preeditLabel.isHidden = text.isEmpty
        renderer?.setCursorSuppressed(!text.isEmpty)
        let content = NSAttributedString(string: text, attributes: [
            .font: UIFont(name: terminalFont.name, size: terminalFont.size) ?? UIFont.monospacedSystemFont(ofSize: terminalFont.size, weight: .regular),
            .foregroundColor: UIColor(red: CGFloat(currentTheme.foreground.0) / 255, green: CGFloat(currentTheme.foreground.1) / 255, blue: CGFloat(currentTheme.foreground.2) / 255, alpha: 1),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        if preeditLabel.attributedText?.isEqual(to: content) != true {
            preeditLabel.attributedText = content
            preeditLabel.sizeToFit()
        }
        let labelFrame = CGRect(origin: origin, size: CGSize(width: min(preeditLabel.intrinsicContentSize.width, max(0, rect.maxX - origin.x)), height: max(0, preeditLabel.intrinsicContentSize.height)))
        if preeditLabel.frame != labelFrame { preeditLabel.frame = labelFrame }
    }


    /// UIKeyInput: tells iOS we always accept text (keeps keyboard open).
    public var hasText: Bool { true }

    /// UIKeyInput: software keyboard character input.
    public func insertText(_ text: String) {
        guard inputEnabled else { return }
        var modifiers = KeyModifiers()
        if _inputAccessory.ctrlActive { modifiers.insert(.control) }
        if _inputAccessory.shiftActive { modifiers.insert(.shift) }
        let hasModifiers = !modifiers.isEmpty

        // QuickPath/swipe often commits whole words at once.
        // Send plain text as a single key event to preserve order.
        if !modifiers.contains(.control), !text.contains("\n") {
            let event = KeyEvent(
                keyCode: 0,
                modifiers: modifiers,
                isKeyDown: true,
                characters: text
            )
            onKeyInput?(event)

            if hasModifiers {
                _inputAccessory.deactivateModifiers()
            }
            return
        }

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
        guard inputEnabled else { return }
        if imeTextField.markedTextRange != nil {
            imeTextField.deleteBackward()
            updatePreeditOverlay()
            return
        }
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
        guard inputEnabled else { return }
        cancelIMEComposition()
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
        copyScreenText()
    }

    private func copyScreenText() {
        guard let emulator = terminalEmulator else { return }

        // If there's an active selection, copy only the selected text.
        if selectionView.selection != nil,
           let selectedText = selectionView.selectedText(from: emulator.state.activeScreen),
           !selectedText.isEmpty {
            UIPasteboard.general.string = selectedText
            selectionView.selection = nil
            return
        }

        // Fallback: copy entire visible screen.
        let text = emulator.state.activeScreen.text()
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    // MARK: - UIResponder Copy/Paste Menu

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return selectionView.selection != nil }
        return false
    }

    @objc public override func copy(_ sender: Any?) {
        copyScreenText()
    }

    @objc public override func paste(_ sender: Any?) {
        handlePaste()
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
        updatePreeditOverlay()
        notifyResizeIfNeeded()
        requestDisplay()
    }

    public func setTheme(_ theme: TerminalTheme) {
        currentTheme = theme
        renderer?.setTheme(theme)
        // Update the clear color to match the theme background.
        self.clearColor = MTLClearColor(
            red: Double(theme.background.0) / 255.0,
            green: Double(theme.background.1) / 255.0,
            blue: Double(theme.background.2) / 255.0,
            alpha: 1.0
        )
        requestDisplay()
    }

    public func setCursorStyle(_ style: CursorStyle) {
        renderer?.setCursorStyle(style)
        requestDisplay()
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

    /// Drawable content rect after applying terminal insets.
    var terminalContentRect: CGRect {
        let rect = bounds.inset(by: terminalContentInsets)
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return rect
    }

    public var gridSize: (columns: Int, rows: Int) {
        guard let renderer = renderer else { return (80, 24) }
        let cellSize = renderer.cellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return (80, 24) }
        let rect = terminalContentRect
        guard rect.width > 0, rect.height > 0 else { return (80, 24) }
        let columns = max(1, Int(rect.width / cellSize.width))
        let rows = max(1, Int(rect.height / cellSize.height))
        return (columns, rows)
    }

    /// Convert a point in view coordinates to a clamped terminal grid coordinate.
    func gridCoordinate(for point: CGPoint) -> (row: Int, col: Int) {
        let grid = gridSize
        guard grid.columns > 0, grid.rows > 0 else { return (0, 0) }
        let rect = terminalContentRect.isEmpty ? bounds : terminalContentRect
        let localX = point.x - rect.minX
        let localY = point.y - rect.minY
        let col = max(0, min(Int(localX / cellSize.width), grid.columns - 1))
        let row = max(0, min(Int(localY / cellSize.height), grid.rows - 1))
        return (row, col)
    }

    /// Center point for a row/column selection in view coordinates.
    func selectionCenterPoint(row: Int, startCol: Int, endCol: Int) -> CGPoint {
        let rect = terminalContentRect.isEmpty ? bounds : terminalContentRect
        let centerX = rect.minX + CGFloat(startCol + endCol + 1) / 2.0 * cellSize.width
        let centerY = rect.minY + CGFloat(row) * cellSize.height + cellSize.height / 2.0
        return CGPoint(x: centerX, y: centerY)
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
            self.scrollOffset = 0
            self.onResize?(cols, rows)
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        selectionView.frame = bounds
        selectionView.contentInsets = terminalContentInsets
        selectionView.cellSize = cellSize
        bellLayer?.frame = bounds
        updatePreeditOverlay()
        notifyResizeIfNeeded()
        requestDisplay()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        requestDisplay()
    }

    // MARK: - Hardware Key Input (external keyboards)

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = routeHardwarePresses(presses, with: event, isKeyDown: true)
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = routeHardwarePresses(presses, with: event, isKeyDown: false)
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    private func routeHardwarePresses(_ presses: Set<UIPress>, with event: UIPressesEvent?, isKeyDown: Bool) -> Set<UIPress> {
        guard inputEnabled else { return [] }
        var remaining = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { remaining.insert(press); continue }
            if imeTextField.markedTextRange != nil {
                if key.keyCode == .keyboardEscape {
                    if isKeyDown { cancelIMEComposition() }
                    continue
                }
                if key.keyCode == .keyboardReturnOrEnter { compositionReturnHeld = isKeyDown }
                remaining.insert(press)
                continue
            }
            if key.keyCode == .keyboardReturnOrEnter, compositionReturnHeld {
                if !isKeyDown { compositionReturnHeld = false }
                continue
            }
            let isSpecial = (0x28...0x2B).contains(key.keyCode.rawValue) || (0x3A...0x52).contains(key.keyCode.rawValue)
            let modifiers = key.modifierFlags.intersection([.shift, .alternate, .control, .command])
            // Let UIKit handle app shortcuts, input-method switching, and printable text.
            if modifiers.contains(.command) ||
               ((modifiers == .control || modifiers == [.control, .shift]) && key.charactersIgnoringModifiers == " ") ||
               (!isSpecial && modifiers.subtracting(.shift).isEmpty && !key.characters.isEmpty && key.characters.rangeOfCharacter(from: .controlCharacters) == nil) {
                remaining.insert(press)
                continue
            }
            onKeyInput?(KeyEvent(keyCode: UInt32(key.keyCode.rawValue), modifiers: modifiersFromUIKey(key), isKeyDown: isKeyDown,
                characters: HardwareKeyInterpreter.terminalCharacters(rawCharacters: key.characters, charactersIgnoringModifiers: key.charactersIgnoringModifiers, modifiers: key.modifierFlags)))
        }
        return remaining
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
        guard !isInBackground,
              let emulator = terminalEmulator,
              let renderer = renderer,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable
        else { return }

        updatePreeditOverlay()
        let state = emulator.state.activeScreen
        renderer.update(
            state: state,
            scrollback: emulator.state.scrollback,
            scrollOffset: scrollOffset,
            viewportSize: bounds.size,
            contentRect: terminalContentRect
        )
        renderer.render(to: renderPassDescriptor, drawable: drawable)
    }
}

extension TerminalMetalView: UITextFieldDelegate {
    public func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard inputEnabled else { return false }
        if string == "\n" || string == "\r" {
            if textField.markedTextRange != nil { return false }
            handleIMETextChanged()
            if !compositionReturnHeld { insertText("\n") }
            return false
        }
        return true
    }
}
