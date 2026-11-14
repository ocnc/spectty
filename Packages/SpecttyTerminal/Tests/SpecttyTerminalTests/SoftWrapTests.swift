import XCTest
@testable import SpecttyTerminal

final class SoftWrapTests: XCTestCase {
    func testWrapOnlyMarkedWhenNextCharacterArrives() {
        let emulator = GhosttyTerminalEmulator(columns: 4, rows: 3)
        emulator.feed(Data("abcd".utf8))
        XCTAssertNil(emulator.state.activeScreen.lines[0].wrappedColumns)
        emulator.feed(Data("e".utf8))
        XCTAssertEqual(emulator.state.activeScreen.lines[0].wrappedColumns, 4)
        emulator.feed(Data("\r\nf".utf8))
        XCTAssertNil(emulator.state.activeScreen.lines[1].wrappedColumns)
        emulator.feed(Data("\u{1b}[1;2H\u{1b}[K".utf8))
        XCTAssertNil(emulator.state.activeScreen.lines[0].wrappedColumns)
    }

    func testWideWrapExcludesPaddingAndSurvivesScrollback() {
        let emulator = GhosttyTerminalEmulator(columns: 4, rows: 2)
        emulator.feed(Data("abc中def".utf8))
        XCTAssertEqual(emulator.state.scrollback.line(at: 0)?.wrappedColumns, 3)
        XCTAssertEqual(emulator.state.activeScreen.lines[0].wrappedColumns, 4)
        emulator.feed(Data("\u{1b}[2J".utf8))
        XCTAssertTrue(emulator.state.activeScreen.lines.allSatisfy { $0.wrappedColumns == nil })
    }
}
