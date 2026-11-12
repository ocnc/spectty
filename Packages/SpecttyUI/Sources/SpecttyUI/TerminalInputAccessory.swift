import UIKit
import SpecttyTerminal

/// Two-row input accessory providing common terminal keys above the iOS
/// software keyboard.
public final class TerminalInputAccessory: UIInputView {
    /// Callback when a virtual key is pressed.
    public var onKeyPress: ((KeyEvent) -> Void)?
    /// Callback when the software keyboard should be shown or hidden.
    public var onKeyboardToggle: (() -> Void)?

    /// Whether Ctrl modifier is active (toggleable).
    public private(set) var ctrlActive = false
    /// Whether Shift modifier is active (toggleable).
    public private(set) var shiftActive = false
    /// Whether the software keyboard is currently visible.
    public var softwareKeyboardVisible = true {
        didSet {
            updateKeyboardToggleButton()
        }
    }

    private let stackView = UIStackView()
    private var ctrlButton: UIButton?
    private var shiftButton: UIButton?
    private var keyboardToggleButton: UIButton?
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)

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

        let heightConstraint = heightAnchor.constraint(equalToConstant: 100)
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            heightConstraint,
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])

        let firstRowKeys: [(String, KeyButtonAction)] = [
            ("Esc", .escape),
            ("Tab", .tab),
            ("Ctrl", .toggleCtrl),
            ("Shift", .toggleShift),
            ("\u{2190}", .arrowLeft),   // ←
            ("\u{2193}", .arrowDown),   // ↓
            ("\u{2191}", .arrowUp),     // ↑
            ("\u{2192}", .arrowRight),  // →
        ]
        addRow(firstRowKeys)

        let secondRowKeys: [(String, KeyButtonAction)] = [
            ("Del", .deleteForward),
            ("PgUp", .pageUp),
            ("PgDn", .pageDown),
            ("Hide KB", .toggleSoftwareKeyboard),
        ]
        addRow(secondRowKeys)
        updateKeyboardToggleButton()
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 100)
    }

    // MARK: - Button Factory

    private enum KeyButtonAction {
        case escape
        case tab
        case deleteForward
        case pageUp
        case pageDown
        case toggleCtrl
        case toggleShift
        case toggleSoftwareKeyboard
        case arrowUp
        case arrowDown
        case arrowLeft
        case arrowRight
    }

    private func addRow(_ keys: [(String, KeyButtonAction)]) {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 5
        row.alignment = .fill
        row.distribution = .fillEqually

        for (title, action) in keys {
            let button = makeButton(title: title, action: action)
            row.addArrangedSubview(button)

            if case .toggleCtrl = action { ctrlButton = button }
            if case .toggleShift = action { shiftButton = button }
            if case .toggleSoftwareKeyboard = action { keyboardToggleButton = button }
        }

        stackView.addArrangedSubview(row)
    }

    private func makeButton(title: String, action: KeyButtonAction) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .label
        config.baseBackgroundColor = .systemGray4
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            return out
        }

        let button = UIButton(configuration: config)
        switch action {
        case .escape: button.accessibilityLabel = "Escape"
        case .deleteForward: button.accessibilityLabel = "Delete forward"
        case .pageUp: button.accessibilityLabel = "Page up"
        case .pageDown: button.accessibilityLabel = "Page down"
        case .arrowUp: button.accessibilityLabel = "Up arrow"
        case .arrowDown: button.accessibilityLabel = "Down arrow"
        case .arrowLeft: button.accessibilityLabel = "Left arrow"
        case .arrowRight: button.accessibilityLabel = "Right arrow"
        case .toggleCtrl: button.accessibilityLabel = "Control"
        default: button.accessibilityLabel = title
        }
        let handler = UIAction { [weak self] _ in
            self?.handleAction(action)
        }
        button.addAction(handler, for: .touchUpInside)

        return button
    }

    // MARK: - Key Actions

    private func handleAction(_ action: KeyButtonAction) {
        haptic.impactOccurred()

        var modifiers = KeyModifiers()
        if ctrlActive { modifiers.insert(.control) }
        if shiftActive { modifiers.insert(.shift) }

        switch action {
        case .escape:
            sendKey(keyCode: 0x29, characters: "\u{1B}", modifiers: modifiers)
            deactivateModifiers()
        case .tab:
            sendKey(keyCode: 0x2B, characters: "\t", modifiers: modifiers)
            deactivateModifiers()
        case .deleteForward:
            sendKey(keyCode: 0x4C, characters: "", modifiers: modifiers)
            deactivateModifiers()
        case .pageUp:
            sendKey(keyCode: 0x4B, characters: "", modifiers: modifiers)
            deactivateModifiers()
        case .pageDown:
            sendKey(keyCode: 0x4E, characters: "", modifiers: modifiers)
            deactivateModifiers()
        case .toggleCtrl:
            ctrlActive.toggle()
            updateModifierButtons()
        case .toggleShift:
            shiftActive.toggle()
            updateModifierButtons()
        case .toggleSoftwareKeyboard:
            deactivateModifiers()
            onKeyboardToggle?()
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
        updateModifierButtons()
    }

    private func updateModifierButtons() {
        updateButtonHighlight(ctrlButton, active: ctrlActive)
        updateButtonHighlight(shiftButton, active: shiftActive)
    }

    private func updateKeyboardToggleButton() {
        guard let keyboardToggleButton else { return }
        var config = keyboardToggleButton.configuration ?? .filled()
        config.title = softwareKeyboardVisible ? "Hide KB" : "Show KB"
        keyboardToggleButton.configuration = config
        keyboardToggleButton.accessibilityLabel = softwareKeyboardVisible ? "Hide keyboard" : "Show keyboard"
    }

    private func updateButtonHighlight(_ button: UIButton?, active: Bool) {
        guard let button else { return }
        button.accessibilityValue = active ? "On" : "Off"
        if active { button.accessibilityTraits.insert(.selected) } else { button.accessibilityTraits.remove(.selected) }
        var config = button.configuration ?? .filled()
        config.baseBackgroundColor = active
            ? .systemBlue
            : .systemGray4
        config.baseForegroundColor = active ? .white : .label
        button.configuration = config
    }
}
