import XCTest
import Metal
import SpecttyTerminal
@testable import SpecttyUI

final class InputAccessoryTests: XCTestCase {
    @MainActor func testHelperKeysAndModifierAccessibility() {
        let bar = TerminalInputAccessory(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        let buttons = descendants(of: bar).compactMap { $0 as? UIButton }
        var codes = [UInt32]()
        bar.onKeyPress = { codes.append($0.keyCode) }
        for label in ["Delete forward", "Page up", "Page down"] {
            let button = buttons.first { $0.accessibilityLabel == label }
            XCTAssertNotNil(button)
            button?.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(codes, [0x4C, 0x4B, 0x4E])
        let control = buttons.first { $0.accessibilityLabel == "Control" }
        control?.sendActions(for: .touchUpInside)
        XCTAssertTrue(bar.ctrlActive)
        XCTAssertTrue(control?.accessibilityTraits.contains(.selected) == true)
        XCTAssertEqual(control?.accessibilityValue, "On")
        bar.softwareKeyboardVisible = false
        XCTAssertNotNil(buttons.first { $0.accessibilityLabel == "Show keyboard" })
    }

    @MainActor func testBarReservesSpaceOnceAcrossPhoneAndTabletSizes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let emulator = GhosttyTerminalEmulator(columns: 80, rows: 24)
        let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), emulator: emulator)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        for size in [CGSize(width: 390, height: 700), CGSize(width: 700, height: 390), CGSize(width: 1024, height: 768)] {
            view.frame.size = size
            view.setNeedsLayout()
            view.layoutIfNeeded()
            let bar = try XCTUnwrap(view.subviews.first { $0 is TerminalInputAccessory })
            XCTAssertFalse(bar.isHidden)
            XCTAssertEqual(view.terminalContentRect.maxY, bar.frame.minY - 4, accuracy: 1)
            XCTAssertNil(view.inputAccessoryView)
            XCTAssertNil(view.imeTextField.inputAccessoryView)
        }
    }

    @MainActor private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
