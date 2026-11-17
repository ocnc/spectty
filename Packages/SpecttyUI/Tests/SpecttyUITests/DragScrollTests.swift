import XCTest
import Metal
import SpecttyTerminal
@testable import SpecttyUI

final class DragScrollTests: XCTestCase {
    /// The modes herdr turns on: alternate screen with button, any-motion and SGR mouse reports.
    private let mouseTrackingApp = Data("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h".utf8)

    @MainActor func testDragReportsWheelAtCellWhereItStarted() throws {
        let terminal = try DragTerminal()
        defer { terminal.close() }
        terminal.emulator.feed(mouseTrackingApp)
        let line = terminal.view.cellSize.height
        let start = terminal.center(column: 10, row: 5)

        // UIKit recognizes the pan once the finger has moved a little.
        XCTAssertFalse(terminal.handler.handleDrag(.began, at: start.movedDown(6), translation: CGPoint(x: 0, y: 6)))
        // Less than a line is kept for the next update.
        XCTAssertFalse(terminal.handler.handleDrag(.changed, at: start.movedDown(line / 2), translation: CGPoint(x: 0, y: line / 2)))
        XCTAssertTrue(terminal.sent.isEmpty)

        // Down two and a half lines: two wheel-up presses at the starting cell, not under the finger.
        XCTAssertTrue(terminal.handler.handleDrag(.changed, at: start.movedDown(line * 2.5), translation: CGPoint(x: 0, y: line * 2.5)))
        XCTAssertEqual(terminal.sent, ["\u{1b}[<64;10;5M", "\u{1b}[<64;10;5M"])

        // The caller reset the translation; up one line is one wheel-down press at the same cell.
        terminal.sent.removeAll()
        XCTAssertTrue(terminal.handler.handleDrag(.changed, at: start.movedDown(line * 1.5), translation: CGPoint(x: 0, y: -line)))
        XCTAssertEqual(terminal.sent, ["\u{1b}[<65;10;5M"])

        XCTAssertFalse(terminal.handler.handleDrag(.ended, at: start.movedDown(line * 1.5), translation: .zero))
        XCTAssertEqual(terminal.sent.count, 1)
    }

    @MainActor func testEachDragReportsAtItsOwnStart() throws {
        let terminal = try DragTerminal()
        defer { terminal.close() }
        terminal.emulator.feed(mouseTrackingApp)
        let line = terminal.view.cellSize.height

        for (column, row) in [(3, 2), (12, 9)] {
            let start = terminal.center(column: column, row: row)
            _ = terminal.handler.handleDrag(.began, at: start, translation: .zero)
            XCTAssertTrue(terminal.handler.handleDrag(.changed, at: start.movedDown(-line), translation: CGPoint(x: 0, y: -line)))
            _ = terminal.handler.handleDrag(.ended, at: start.movedDown(-line), translation: .zero)
        }
        XCTAssertEqual(terminal.sent, ["\u{1b}[<65;3;2M", "\u{1b}[<65;12;9M"])
    }

    @MainActor func testDragOnNormalScreenScrollsLocalScrollback() throws {
        let terminal = try DragTerminal()
        defer { terminal.close() }
        terminal.emulator.feed(Data(String(repeating: "line\r\n", count: 40).utf8))
        let line = terminal.view.cellSize.height
        let start = terminal.center(column: 10, row: 5)
        XCTAssertTrue(terminal.view.isShowingLiveScreen)

        _ = terminal.handler.handleDrag(.began, at: start, translation: .zero)
        XCTAssertTrue(terminal.handler.handleDrag(.changed, at: start.movedDown(line * 2), translation: CGPoint(x: 0, y: line * 2)))
        XCTAssertTrue(terminal.sent.isEmpty)
        XCTAssertFalse(terminal.view.isShowingLiveScreen)
    }
}

/// A terminal view in a window, with its gesture handler and the mouse reports it sent.
@MainActor
private final class DragTerminal {
    let emulator = GhosttyTerminalEmulator(columns: 80, rows: 24)
    let view: TerminalMetalView
    let handler: GestureHandler
    var sent = [String]()
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000))

    init() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), emulator: emulator)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        handler = GestureHandler(metalView: view, emulator: emulator)
        handler.onMouseEvent = { [unowned self] in sent.append(String(decoding: $0, as: UTF8.self)) }
    }

    func close() {
        window.isHidden = true
    }

    /// The center of a cell, counting from 1 as mouse reports do.
    func center(column: Int, row: Int) -> CGPoint {
        let rect = view.terminalContentRect
        return CGPoint(
            x: rect.minX + (CGFloat(column) - 0.5) * view.cellSize.width,
            y: rect.minY + (CGFloat(row) - 0.5) * view.cellSize.height
        )
    }
}

private extension CGPoint {
    func movedDown(_ distance: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y + distance)
    }
}
