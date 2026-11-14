import UIKit
import SpecttyTerminal

/// Compact terminal keys and optional voice input above the software keyboard.
public final class TerminalInputAccessory: UIInputView {
    /// Callback when a virtual key is pressed.
    public var onKeyPress: ((KeyEvent) -> Void)?
    static let barHeight: CGFloat = 52

    public var onVoiceInput: (() -> Void)? {
        didSet { voiceButton?.isHidden = onVoiceInput == nil }
    }
    private var voiceButton: UIButton?
    private var expandButton: UIButton?
    private var navigationRow: UIStackView?
    private var expanded = false

    /// Whether Ctrl modifier is active (toggleable).
    public private(set) var ctrlActive = false
    /// Whether Shift modifier is active (toggleable).
    public private(set) var shiftActive = false
    public private(set) var altActive = false
    private let stackView = UIStackView()
    private var ctrlButton: UIButton?
    private var shiftButton: UIButton?
    private var altButton: UIButton?
    private var buttons: [UIButton] = []
    private var keyGroups: [UIView] = []
    private var foreground = UIColor.white
    private let haptic = UIImpactFeedbackGenerator(style: .soft)

    public init(frame: CGRect) {
        super.init(frame: frame, inputViewStyle: .keyboard)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        allowsSelfSizing = true

        stackView.axis = .vertical
        stackView.spacing = 4
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        let navigation = makeRow([
            ("Alt", .toggleAlt), ("←", .arrowLeft), ("↓", .arrowDown),
            ("↑", .arrowUp), ("→", .arrowRight), ("Newline", .newline)
        ])
        navigation.distribution = .fillEqually
        styleKeyGroup(navigation)
        navigation.isHidden = true
        navigationRow = navigation
        stackView.addArrangedSubview(navigation)

        let main = UIStackView()
        main.axis = .horizontal
        main.spacing = 6
        let shortcuts = makeRow([("Esc", .escape), ("Tab", .tab), ("Ctrl", .toggleCtrl), ("Shift", .toggleShift)])
        styleKeyGroup(shortcuts)
        main.addArrangedSubview(shortcuts)
        main.addArrangedSubview(UIView())
        main.addArrangedSubview(makeButton(title: "More keys", action: .expand))
        let mic = makeButton(title: "Voice input", action: .voiceInput)
        voiceButton = mic
        mic.isHidden = onVoiceInput == nil
        main.addArrangedSubview(mic)
        stackView.addArrangedSubview(main)
        setTheme(.default)
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: expanded ? 100 : Self.barHeight)
    }

    // MARK: - Button Factory

    private enum KeyButtonAction {
        case expand
        case voiceInput
        case escape
        case tab
        case toggleCtrl
        case toggleShift
        case toggleAlt
        case newline
        case arrowUp
        case arrowDown
        case arrowLeft
        case arrowRight
    }

    private func makeRow(_ keys: [(String, KeyButtonAction)]) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        for (title, action) in keys {
            let button = makeButton(title: title, action: action)
            row.addArrangedSubview(button)
            if case .toggleCtrl = action { ctrlButton = button }
            if case .toggleShift = action { shiftButton = button }
            if case .toggleAlt = action { altButton = button }
        }
        return row
    }

    private func makeButton(title: String, action: KeyButtonAction) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = .secondaryLabel
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            return out
        }

        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let button = UIButton(configuration: config)
        buttons.append(button)
        let width = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        width.priority = .defaultHigh
        width.isActive = true
        let height = button.heightAnchor.constraint(equalToConstant: 44)
        height.priority = .defaultHigh
        height.isActive = true
        switch action {
        case .expand:
            expandButton = button
            button.configuration?.title = nil
            button.configuration?.image = UIImage(systemName: "keyboard")
            button.accessibilityLabel = "Show navigation keys"
            button.accessibilityValue = "Collapsed"
        case .voiceInput:
            button.configuration?.title = nil
            button.configuration?.image = UIImage(systemName: "mic.fill")
            button.accessibilityLabel = "Voice input"
        case .escape: button.accessibilityLabel = "Escape"
        case .arrowUp: button.accessibilityLabel = "Up arrow"
        case .arrowDown: button.accessibilityLabel = "Down arrow"
        case .arrowLeft: button.accessibilityLabel = "Left arrow"
        case .arrowRight: button.accessibilityLabel = "Right arrow"
        case .toggleCtrl: button.accessibilityLabel = "Control"
        case .newline: button.accessibilityLabel = "Newline (Control J)"
        default: button.accessibilityLabel = title
        }
        let symbol: String?
        switch action {
        case .arrowUp: symbol = "arrow.up"
        case .arrowDown: symbol = "arrow.down"
        case .arrowLeft: symbol = "arrow.left"
        case .arrowRight: symbol = "arrow.right"
        case .toggleShift: symbol = "shift"
        case .newline: symbol = "return"
        default: symbol = nil
        }
        if let symbol {
            button.configuration?.title = nil
            button.configuration?.image = UIImage(systemName: symbol)
        }
        let handler = UIAction { [weak self] _ in
            self?.handleAction(action)
        }
        button.addAction(handler, for: .touchUpInside)

        return button
    }

    private func styleKeyGroup(_ group: UIView) {
        group.layer.cornerRadius = 16
        group.layer.cornerCurve = .continuous
        keyGroups.append(group)
    }

    func setTheme(_ theme: TerminalTheme) {
        let background = UIColor(red: CGFloat(theme.background.0) / 255, green: CGFloat(theme.background.1) / 255, blue: CGFloat(theme.background.2) / 255, alpha: 1)
        foreground = UIColor(red: CGFloat(theme.foreground.0) / 255, green: CGFloat(theme.foreground.1) / 255, blue: CGFloat(theme.foreground.2) / 255, alpha: 1)
        backgroundColor = background
        for group in keyGroups { group.backgroundColor = foreground.withAlphaComponent(0.06) }
        for button in buttons { button.configuration?.baseForegroundColor = foreground.withAlphaComponent(0.85) }
        expandButton?.configuration?.background.backgroundColor = foreground.withAlphaComponent(0.06)
        voiceButton?.configuration?.background.backgroundColor = foreground
        voiceButton?.configuration?.baseForegroundColor = background
        updateModifierButtons()
    }

    // MARK: - Key Actions

    private func handleAction(_ action: KeyButtonAction) {
        haptic.impactOccurred()

        var modifiers = KeyModifiers()
        if ctrlActive { modifiers.insert(.control) }
        if shiftActive { modifiers.insert(.shift) }
        if altActive { modifiers.insert(.alt) }

        switch action {
        case .expand:
            expanded.toggle()
            if !expanded { deactivateModifiers() }
            navigationRow?.isHidden = !expanded
            expandButton?.configuration?.image = UIImage(systemName: expanded ? "keyboard.chevron.compact.down" : "keyboard")
            expandButton?.accessibilityLabel = expanded ? "Hide navigation keys" : "Show navigation keys"
            expandButton?.accessibilityValue = expanded ? "Expanded" : "Collapsed"
            invalidateIntrinsicContentSize()
            superview?.setNeedsLayout()
        case .newline:
            sendKey(keyCode: 0x0D, characters: "j", modifiers: [.control])
            deactivateModifiers()
        case .toggleAlt:
            altActive.toggle()
            updateModifierButtons()
        case .voiceInput:
            deactivateModifiers()
            onVoiceInput?()
        case .escape:
            sendKey(keyCode: 0x29, characters: "\u{1B}", modifiers: modifiers)
            deactivateModifiers()
        case .tab:
            sendKey(keyCode: 0x2B, characters: "\t", modifiers: modifiers)
            deactivateModifiers()
        case .toggleCtrl:
            ctrlActive.toggle()
            updateModifierButtons()
        case .toggleShift:
            shiftActive.toggle()
            updateModifierButtons()
        case .arrowUp:
            sendKey(keyCode: 0x52, characters: "", modifiers: modifiers)
            deactivateModifiers()
        case .arrowDown:
            sendKey(keyCode: 0x51, characters: "", modifiers: modifiers)
            deactivateModifiers()
        case .arrowLeft:
            sendKey(keyCode: 0x50, characters: "", modifiers: modifiers)
            deactivateModifiers()
        case .arrowRight:
            sendKey(keyCode: 0x4F, characters: "", modifiers: modifiers)
            deactivateModifiers()
        }
    }

    private func sendKey(keyCode: UInt32, characters: String, modifiers: KeyModifiers) {
        let event = KeyEvent(
            keyCode: keyCode,
            modifiers: modifiers,
            isKeyDown: true,
            characters: characters
        )
        onKeyPress?(event)
    }

    public func deactivateModifiers() {
        ctrlActive = false
        shiftActive = false
        altActive = false
        updateModifierButtons()
    }

    private func updateModifierButtons() {
        updateButtonHighlight(ctrlButton, active: ctrlActive)
        updateButtonHighlight(shiftButton, active: shiftActive)
        updateButtonHighlight(altButton, active: altActive)
    }

    private func updateButtonHighlight(_ button: UIButton?, active: Bool) {
        guard let button else { return }
        button.accessibilityValue = active ? "On" : "Off"
        if active { button.accessibilityTraits.insert(.selected) } else { button.accessibilityTraits.remove(.selected) }
        var config = button.configuration ?? .plain()
        config.background.backgroundColor = active ? foreground.withAlphaComponent(0.2) : .clear
        config.baseForegroundColor = active ? foreground : foreground.withAlphaComponent(0.85)
        button.configuration = config
    }
}
