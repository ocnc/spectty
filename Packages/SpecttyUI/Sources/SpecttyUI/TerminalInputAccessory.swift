import UIKit
import SpecttyTerminal

/// Input accessory bar providing Esc, Tab, Ctrl, Alt, arrow keys, and other
/// common terminal keys above the iOS software keyboard.
public final class TerminalInputAccessory: UIInputView {
    /// Callback when a virtual key is pressed.
    public var onKeyPress: ((KeyEvent) -> Void)?

    /// Whether Ctrl modifier is active (toggleable).
    public private(set) var ctrlActive = false
    /// Whether Shift modifier is active (toggleable).
    public private(set) var shiftActive = false

    private let stackView = UIStackView()
    private var ctrlButton: UIButton?
    private var shiftButton: UIButton?
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

        stackView.axis = .horizontal
        stackView.spacing = 5
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        let heightConstraint = heightAnchor.constraint(equalToConstant: 44)
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            heightConstraint,
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])

        // Build the key buttons — optimized for CLI coding (Claude Code / Codex).
        let keys: [(String, KeyButtonAction)] = [
            ("Esc", .escape),
            ("Tab", .tab),
            ("Ctrl", .toggleCtrl),
            ("Shift", .toggleShift),
            ("\u{2190}", .arrowLeft),   // ←
            ("\u{2193}", .arrowDown),   // ↓
            ("\u{2191}", .arrowUp),     // ↑
            ("\u{2192}", .arrowRight),  // →
        ]

        for (title, action) in keys {
            let button = makeButton(title: title, action: action)
            stackView.addArrangedSubview(button)

            if case .toggleCtrl = action { ctrlButton = button }
            if case .toggleShift = action { shiftButton = button }
        }
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    // MARK: - Button Factory

    private enum KeyButtonAction {
        case escape
        case tab
        case toggleCtrl
        case toggleShift
        case arrowUp
        case arrowDown
        case arrowLeft
        case arrowRight
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
        updateModifierButtons()
    }

    private func updateModifierButtons() {
        updateButtonHighlight(ctrlButton, active: ctrlActive)
        updateButtonHighlight(shiftButton, active: shiftActive)
    }

    private func updateButtonHighlight(_ button: UIButton?, active: Bool) {
        guard let button else { return }
        var config = button.configuration ?? .filled()
        config.baseBackgroundColor = active
            ? .systemBlue
            : .systemGray4
        config.baseForegroundColor = active ? .white : .label
        button.configuration = config
    }
}
