import XCTest
import Metal
import SpecttyTerminal
@testable import SpecttyUI

final class IMEInputTests: XCTestCase {
    private let emulator = GhosttyTerminalEmulator(columns: 80, rows: 24)
    @MainActor func testMarkedTextStaysLocalAndCommitIsSentOnce() throws {
        let view = try makeView()
        var sent = [String]()
        view.onKeyInput = { if $0.isKeyDown { sent.append($0.characters) } }
        view.imeTextField.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        view.handleIMETextChanged()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(view.preeditLabel.isHidden)
        XCTAssertFalse(view.textField(view.imeTextField, shouldChangeCharactersIn: NSRange(location: 5, length: 0), replacementString: "\n"))
        XCTAssertTrue(sent.isEmpty)
        view.imeTextField.unmarkText()
        view.imeTextField.text = "中文"
        view.handleIMETextChanged()
        view.handleIMETextChanged()
        XCTAssertEqual(sent, ["中文"])
        XCTAssertTrue(view.preeditLabel.isHidden)
    }

    @MainActor func testSwitchAndDisconnectDiscardComposition() throws {
        let view = try makeView()
        var sent = [String]()
        view.onKeyInput = { sent.append($0.characters) }
        view.imeTextField.setMarkedText("pending", selectedRange: NSRange(location: 7, length: 0))
        let next = GhosttyTerminalEmulator(columns: 80, rows: 24)
        view.setEmulator(next)
        view.handleIMETextChanged()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(view.imeTextField.text, "")
        view.imeTextField.setMarkedText("other", selectedRange: NSRange(location: 5, length: 0))
        view.setInputEnabled(false)
        view.insertText("blocked")
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(view.imeTextField.markedTextRange)
    }

    @MainActor private func makeView() throws -> TerminalMetalView {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        return TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), emulator: emulator)
    }
}
