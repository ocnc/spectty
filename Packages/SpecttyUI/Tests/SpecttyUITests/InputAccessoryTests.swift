import XCTest
import Metal
import SpecttyTerminal
@testable import SpecttyUI

final class InputAccessoryTests: XCTestCase {
    @MainActor func testVoiceButtonIsOptInAndDoesNotSendKeys() throws {
        let bar = TerminalInputAccessory(frame: CGRect(x: 0, y: 0, width: 390, height: 52))
        let mic = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Voice input" })
        XCTAssertTrue(mic.isHidden)
        var opened = false
        bar.onVoiceInput = { opened = true }
        bar.onKeyPress = { _ in XCTFail("Voice button must not send a terminal key") }
        XCTAssertFalse(mic.isHidden)
        mic.sendActions(for: .touchUpInside)
        XCTAssertTrue(opened)
        bar.onVoiceInput = nil
        XCTAssertTrue(mic.isHidden)
    }

    @MainActor func testNavigationExpansionPreservesKeyActionsAndClearsHiddenModifiers() throws {
        let bar = TerminalInputAccessory(frame: CGRect(x: 0, y: 0, width: 390, height: 52))
        let buttons = descendants(of: bar).compactMap { $0 as? UIButton }
        let expand = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "Show navigation keys" })
        let shift = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "Shift" })
        let alt = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "Alt" })
        XCTAssertTrue(alt.superview!.isHidden)
        let left = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "Left arrow" })
        XCTAssertFalse(shift.superview!.isHidden)
        var events: [KeyEvent] = []
        bar.onKeyPress = { events.append($0) }
        expand.sendActions(for: .touchUpInside)
        XCTAssertFalse(shift.superview!.isHidden)
        XCTAssertEqual(bar.intrinsicContentSize.height, 100)
        XCTAssertFalse(alt.superview!.isHidden)
        XCTAssertTrue(events.isEmpty)
        shift.sendActions(for: .touchUpInside)
        left.sendActions(for: .touchUpInside)
        XCTAssertEqual(events.first?.keyCode, 0x50)
        XCTAssertTrue(events.first!.modifiers.contains(.shift))
        shift.sendActions(for: .touchUpInside)
        expand.sendActions(for: .touchUpInside)
        XCTAssertFalse(bar.shiftActive)
        XCTAssertFalse(shift.superview!.isHidden)
        XCTAssertEqual(bar.intrinsicContentSize.height, 52)
    }

    @MainActor func testTUIShortcutsEncodeExactBytes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let emulator = GhosttyTerminalEmulator(columns: 80, rows: 24)
        let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), emulator: emulator)
        let buttons = descendants(of: view).compactMap { $0 as? UIButton }
        var sent = Data()
        view.onKeyInput = { sent.append(emulator.encodeKey($0)) }
        func tap(_ label: String) throws {
            try XCTUnwrap(buttons.first { $0.accessibilityLabel == label }).sendActions(for: .touchUpInside)
        }
        try tap("Shift")
        try tap("Tab")
        XCTAssertEqual(sent, Data("\u{1B}[Z".utf8))
        sent = Data()
        try tap("Show navigation keys")
        try tap("Alt")
        view.insertText("b")
        view.insertText("x")
        XCTAssertEqual(sent, Data("\u{1B}bx".utf8))
        sent = Data()
        try tap("Newline (Control J)")
        XCTAssertEqual(sent, Data([0x0A]))
        sent = Data()
        try tap("Alt")
        view.deleteBackward()
        XCTAssertEqual(sent, Data([0x1B, 0x7F]))
    }

    func testPasteEncoding() {
        XCTAssertEqual(TerminalPaste.data(for: "hello", bracketed: false), Data("hello".utf8))
        XCTAssertEqual(TerminalPaste.data(for: "hello", bracketed: true), Data("\u{1B}[200~hello\u{1B}[201~".utf8))
    }

    @MainActor func testHelperKeysAndModifierAccessibility() {
        let bar = TerminalInputAccessory(frame: CGRect(x: 0, y: 0, width: 400, height: 52))
        let buttons = descendants(of: bar).compactMap { $0 as? UIButton }
        var codes = [UInt32]()
        bar.onKeyPress = { codes.append($0.keyCode) }
        for label in ["Delete forward", "Page up", "Page down", "Hide keyboard", "Show keyboard"] {
            XCTAssertNil(buttons.first { $0.accessibilityLabel == label })
        }
        XCTAssertEqual(bar.intrinsicContentSize.height, 52)
        buttons.first { $0.accessibilityLabel == "Escape" }?.sendActions(for: .touchUpInside)
        XCTAssertEqual(codes, [0x29])
        let control = buttons.first { $0.accessibilityLabel == "Control" }
        control?.sendActions(for: .touchUpInside)
        XCTAssertTrue(bar.ctrlActive)
        XCTAssertTrue(control?.accessibilityTraits.contains(.selected) == true)
        XCTAssertEqual(control?.accessibilityValue, "On")
    }

    @MainActor func testBarReservesSpaceOnceAcrossPhoneAndTabletSizes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let emulator = GhosttyTerminalEmulator(columns: 80, rows: 24)
        let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), emulator: emulator)
        view.onVoiceInput = {}
        view.setTheme(.catppuccinLatte)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        for size in [CGSize(width: 320, height: 568), CGSize(width: 390, height: 700), CGSize(width: 700, height: 390), CGSize(width: 1024, height: 768)] {
            view.frame.size = size
            view.setNeedsLayout()
            view.layoutIfNeeded()
            let bar = try XCTUnwrap(view.subviews.first { $0 is TerminalInputAccessory })
            XCTAssertFalse(bar.isHidden)
            for button in descendants(of: bar).compactMap({ $0 as? UIButton }) where button.superview?.isHidden == false && !button.isHidden {
                XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
                XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
            }
            XCTAssertEqual(view.terminalContentRect.maxY, bar.frame.minY - 4, accuracy: 1)
            let expand = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Show navigation keys" })
            expand.sendActions(for: .touchUpInside)
            view.layoutIfNeeded()
            XCTAssertEqual(bar.frame.height, 100, accuracy: 1)
            XCTAssertEqual(view.terminalContentRect.maxY, bar.frame.minY - 4, accuracy: 1)
            expand.sendActions(for: .touchUpInside)
            view.layoutIfNeeded()
            XCTAssertEqual(bar.frame.height, 52, accuracy: 1)
            XCTAssertNil(view.inputAccessoryView)
            XCTAssertNil(view.imeTextField.inputAccessoryView)
        }
    }

    @MainActor private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

}
