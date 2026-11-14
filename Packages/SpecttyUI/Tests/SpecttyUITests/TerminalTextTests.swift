import XCTest
import Metal
import SpecttyTerminal
@testable import SpecttyUI

final class TerminalTextTests: XCTestCase {
    @MainActor func testCopyJoinsSoftWrapsButKeepsHardNewlinesAndSpaces() {
        for (input, expected) in [
            ("1234  next\r\nlast", "1234  next\nlast"),
            ("abc中def", "abc中def"),
            ("12345\r\nabc", "12345\nabc")
        ] {
            let emulator = GhosttyTerminalEmulator(columns: 5, rows: 5)
            emulator.feed(Data(input.utf8))
            let view = TextSelectionView(frame: .zero)
            view.selection = TerminalSelection(startRow: 0, startCol: 0, endRow: emulator.state.activeScreen.cursor.row, endCol: 4)
            XCTAssertEqual(view.selectedText(from: emulator.state.activeScreen), expected)
        }
    }

    func testWrappedLinkHitTestingWithWideAndEmojiPrefix() throws {
        let emulator = GhosttyTerminalEmulator(columns: 16, rows: 8)
        let url = "https://example.com/oauth?code=abc&state=xyz"
        emulator.feed(Data("中😀 \(url) done".utf8))
        let lines = emulator.state.activeScreen.lines
        for row in 0...2 {
            let link = try XCTUnwrap(TerminalText.link(atRow: row, col: 8, in: lines))
            XCTAssertEqual(link.url.absoluteString, url)
            XCTAssertEqual(link.selection.startCol, 5)
            XCTAssertEqual(link.selection.endRow, 3)
        }
        XCTAssertNil(TerminalText.link(atRow: 0, col: 0, in: lines))
        XCTAssertNil(TerminalText.link(atRow: 3, col: 2, in: lines))
    }

    func testLinksDoNotJoinAcrossHardNewlinesOrOpenOtherSchemes() {
        let emulator = GhosttyTerminalEmulator(columns: 30, rows: 5)
        emulator.feed(Data("https://example.com/\r\nother\r\nmailto:a@example.com".utf8))
        XCTAssertEqual(TerminalText.link(atRow: 0, col: 5, in: emulator.state.activeScreen.lines)?.url.absoluteString, "https://example.com/")
        XCTAssertNil(TerminalText.link(atRow: 1, col: 1, in: emulator.state.activeScreen.lines))
        XCTAssertNil(TerminalText.link(atRow: 2, col: 10, in: emulator.state.activeScreen.lines))
    }

    @MainActor func testScrollbackSelectionMatchesDisplayedRows() {
        let emulator = GhosttyTerminalEmulator(columns: 8, rows: 3)
        emulator.feed(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))
        for (offset, expected) in [(1, "two\nthree\nfour"), (2, "one\ntwo\nthree")] {
            let lines = TerminalText.visibleLines(state: emulator.state.activeScreen, scrollback: emulator.state.scrollback, scrollOffset: offset)
            let selection = TextSelectionView(frame: .zero)
            selection.selection = TerminalSelection(startRow: 0, startCol: 0, endRow: 2, endCol: 7)
            XCTAssertEqual(selection.selectedText(from: lines), expected)
        }
    }

    @MainActor func testLinkTapKeepsRemoteMousePriority() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let emulator = GhosttyTerminalEmulator(columns: 80, rows: 24)
        emulator.feed(Data("https://example.com".utf8))
        let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), emulator: emulator)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let handler = GestureHandler(metalView: view, emulator: emulator)
        var opened = [URL]()
        var sent = [Data]()
        view.openURL = { opened.append($0) }
        handler.onMouseEvent = { sent.append($0) }
        let point = CGPoint(x: view.terminalContentRect.minX + 1, y: view.terminalContentRect.minY + 1)
        handler.handleTap(at: point)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com"])
        XCTAssertTrue(sent.isEmpty)
        emulator.feed(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        handler.handleTap(at: point)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(sent.count, 1)
    }

    @MainActor func testMenuAndKeyboardClipboardActions() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let clipboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: clipboard.name) }
        let emulator = GhosttyTerminalEmulator(columns: 5, rows: 3)
        emulator.feed(Data("123456789".utf8))
        let view = TerminalMetalView(frame: .zero, emulator: emulator)
        view.pasteboard = clipboard
        view.selectAll(nil)
        XCTAssertTrue(view.imeTextField.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        view.imeTextField.copy(nil)
        XCTAssertEqual(clipboard.string, "123456789")
        clipboard.string = "hello\nworld"
        var sent = [Data]()
        view.onPaste = { sent.append($0) }
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        view.imeTextField.paste(nil)
        emulator.feed(Data("\u{1b}[?2004h".utf8))
        view.paste(nil)
        XCTAssertEqual(sent, [Data("hello\nworld".utf8), TerminalPaste.data(for: "hello\nworld", bracketed: true)])
        let menu = try XCTUnwrap(view.editMenuInteraction(UIEditMenuInteraction(delegate: nil), menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero), suggestedActions: []))
        XCTAssertTrue(menu.children.contains { ($0 as? UIAction)?.title == "Paste" })
        view.setInputEnabled(false)
        XCTAssertFalse(view.imeTextField.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        view.paste(nil)
        XCTAssertEqual(sent.count, 2)
    }
    func testExplicitHyperlinksKeepLabelsAcrossWrapAndScrollback() throws {
        let emulator = GhosttyTerminalEmulator(columns: 5, rows: 2)
        emulator.feed(Data("\u{1b}]8;;https://example.com/build/42\u{1b}\\View build\u{1b}]8;;\u{1b}\\".utf8))
        let lines = emulator.state.activeScreen.lines
        let link = try XCTUnwrap(TerminalText.link(atRow: 1, col: 2, in: lines))
        XCTAssertEqual(link.url.absoluteString, "https://example.com/build/42")
        XCTAssertEqual(link.selection.startRow, 0)
        XCTAssertEqual(link.selection.endRow, 1)
        emulator.feed(Data("\r\nnext\r\n".utf8))
        let history = TerminalText.visibleLines(state: emulator.state.activeScreen, scrollback: emulator.state.scrollback, scrollOffset: emulator.scrollbackCount)
        XCTAssertEqual(TerminalText.link(atRow: 0, col: 0, in: history)?.url, link.url)
        emulator.feed(Data("\u{1b}[2J\u{1b}[H\u{1b}]8;;file:///etc/passwd\u{1b}\\label\u{1b}]8;;\u{1b}\\".utf8))
        XCTAssertNil(TerminalText.link(atRow: 0, col: 0, in: emulator.state.activeScreen.lines))
    }

}
