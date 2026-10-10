import XCTest
import Metal
import SpecttyTerminal
@testable import SpecttyUI

final class MouseTapTests: XCTestCase {
    @MainActor func testTapRequiresMouseModesAndUsesMatchingReleaseButton() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let emulator = GhosttyTerminalEmulator(columns: 80, rows: 24)
        let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), emulator: emulator)
        let handler = GestureHandler(metalView: view, emulator: emulator)
        var sent = [Data]()
        var localTaps = 0
        handler.onMouseEvent = { sent.append($0) }
        handler.onLocalTap = { localTaps += 1 }
        let point = CGPoint(x: view.terminalContentRect.minX + 1, y: view.terminalContentRect.minY + 1)
        handler.handleTap(at: point)
        XCTAssertEqual(localTaps, 1)
        XCTAssertTrue(sent.isEmpty)
        emulator.feed(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        handler.handleTap(at: point)
        XCTAssertEqual(sent, [Data("\u{1b}[<0;1;1M\u{1b}[<0;1;1m".utf8)])
        emulator.feed(Data(String(repeating: "line\r\n", count: 30).utf8))
        view.scrollBy(1)
        handler.handleTap(at: point)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(localTaps, 2)
        handler.handleTap(at: CGPoint(x: -1, y: -1))
        XCTAssertEqual(sent.count, 1)
    }
}
