import UIKit
import SpecttyTerminal

/// Input accessory bar providing Esc, Tab, Ctrl, Alt, arrow keys, and other
/// common terminal keys above the iOS software keyboard.
public final class TerminalInputAccessory: UIInputView {
    /// Callback when a virtual key is pressed.
    public var onKeyPress: ((KeyEvent) -> Void)?

    /// Whether Ctrl modifier is active (toggleable).
    private var ctrlActive = false
    /// Whether Alt modifier is active (toggleable).
    private var altActive = false

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var ctrlButton: UIButton?
    private var altButton: UIButton?
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

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.spacing = 6
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        let heightConstraint = heightAnchor.constraint(equalToConstant: 44)
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            heightConstraint,
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])

        // Build the key buttons.
        let keys: [(String, KeyButtonAction)] = [
            ("Esc", .escape),
            ("Tab", .tab),
            ("Ctrl", .toggleCtrl),
            ("Alt", .toggleAlt),
            ("|", .character("|")),
            ("~", .character("~")),
            ("-", .character("-")),
            ("/", .character("/")),
            ("\u{2190}", .arrowLeft),   // ←
            ("\u{2193}", .arrowDown),   // ↓
            ("\u{2191}", .arrowUp),     // ↑
            ("\u{2192}", .arrowRight),  // →
        ]

        for (title, action) in keys {
            let button = makeButton(title: title, action: action)
            stackView.addArrangedSubview(button)

            if case .toggleCtrl = action { ctrlButton = button }
            if case .toggleAlt = action { altButton = button }
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
        case toggleAlt
        case character(String)
        case arrowUp
        case arrowDown
        case arrowLeft
        case arrowRight
    }

    private func makeButton(title: String, action: KeyButtonAction) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        button.backgroundColor = UIColor.secondarySystemBackground
        button.layer.cornerRadius = 6
        button.layer.cornerCurve = .continuous

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
        if altActive { modifiers.insert(.alt) }

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
        case .toggleAlt:
            altActive.toggle()
            updateModifierButtons()
        case .character(let ch):
            sendKey(keyCode: 0, characters: ch, modifiers: modifiers)
            deactivateModifiers()
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

    private func deactivateModifiers() {
        ctrlActive = false
        altActive = false
        updateModifierButtons()
    }

    private func updateModifierButtons() {
        ctrlButton?.backgroundColor = ctrlActive
            ? UIColor.systemBlue.withAlphaComponent(0.3)
            : UIColor.secondarySystemBackground
        altButton?.backgroundColor = altActive
            ? UIColor.systemBlue.withAlphaComponent(0.3)
            : UIColor.secondarySystemBackground
    }
}
