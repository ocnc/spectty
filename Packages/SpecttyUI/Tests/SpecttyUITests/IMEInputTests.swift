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
        view.imeTextField.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        view.imeTextField.unmarkText()
        view.handleIMETextChanged()
        view.handleIMETextChanged()
        XCTAssertEqual(sent, ["中文"])
        XCTAssertTrue(view.preeditLabel.isHidden)
    }

    @MainActor func testSwitchAndDisconnectDiscardComposition() async throws {
        let view = try makeView()
        var sent = [String]()
        var editCount = 0
        view.imeTextField.addAction(UIAction { _ in editCount += 1 }, for: .editingChanged)
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
        try await Task.sleep(for: .milliseconds(30))
        let settledEditCount = editCount
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(editCount, settledEditCount, "Cancelling composition must not schedule repeated edits")
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(view.imeTextField.markedTextRange)
    }

    @MainActor func testNativeTypingAndBackspaceSendExactBytes() async throws {
        let view = try makeView()
        let window = focus(view)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        var sent = Data()
        view.onKeyInput = { sent.append(self.emulator.encodeKey($0)) }
        view.imeTextField.insertText("hello")
        try await Task.sleep(for: .milliseconds(30))
        view.imeTextField.insertText(" world")
        try await Task.sleep(for: .milliseconds(30))
        view.imeTextField.deleteBackward()
        try await Task.sleep(for: .milliseconds(30))
        view.imeTextField.sendActions(for: .editingChanged)
        XCTAssertEqual(sent, Data("hello world\u{7f}".utf8))
        XCTAssertEqual(view.imeTextField.text, "")
    }

    @MainActor func testNativeDictationTextAlternativesAreSentOnce() async throws {
        let view = try makeView()
        let window = focus(view)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        var sent = [String]()
        view.onKeyInput = { sent.append($0.characters) }
        view.imeTextField.insertText("hello world", alternatives: ["hello word"], style: .lowConfidence)
        view.imeTextField.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sent, ["hello world"])
        XCTAssertEqual(view.imeTextField.text, "")
    }

    @MainActor func testNativeCompositionCommitIsSentWithoutAnotherKeystroke() async throws {
        let view = try makeView()
        let window = focus(view)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        var sent = [String]()
        view.onKeyInput = { sent.append($0.characters) }
        view.imeTextField.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        view.imeTextField.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(view.preeditLabel.isHidden)
        view.imeTextField.unmarkText()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sent, ["中文"])
        view.handleIMETextChanged()
        XCTAssertEqual(sent, ["中文"])
    }

    @MainActor func testNativeInsertionReplacesCompositionWithoutSendingPreedit() async throws {
        let view = try makeView()
        let window = focus(view)
        defer { window.isHidden = true }
        var sent = [String]()
        view.onKeyInput = { sent.append($0.characters) }
        view.imeTextField.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        view.imeTextField.insertText("中")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sent, ["中"])
        XCTAssertTrue(view.preeditLabel.isHidden)
    }

    @MainActor private func makeView() throws -> TerminalMetalView {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        return TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), emulator: emulator)
    }

    @MainActor private func focus(_ view: TerminalMetalView) -> UIWindow {
        let window = UIWindow(frame: view.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        XCTAssertTrue(view.becomeFirstResponder())
        return window
    }
}
