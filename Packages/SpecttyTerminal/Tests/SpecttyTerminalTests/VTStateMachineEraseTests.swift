import XCTest
@testable import SpecttyTerminal

final class VTStateMachineEraseTests: XCTestCase {
    func testEraseInLineClearsRegularCharactersToEndOfLine() {
        let emulator = GhosttyTerminalEmulator(columns: 8, rows: 4)

        emulator.feed(Data("abcdef".utf8))
        emulator.feed(Data("\r\u{1b}[4G\u{1b}[K".utf8))

        let cells = emulator.state.activeScreen.lines[0].cells
        XCTAssertEqual(cells[0].character, "a")
        XCTAssertEqual(cells[1].character, "b")
        XCTAssertEqual(cells[2].character, "c")
        XCTAssertEqual(cells[3].character, " ")
        XCTAssertEqual(cells[4].character, " ")
        XCTAssertEqual(cells[5].character, " ")
    }

    func testEraseCharsClearsRegularCharactersWithoutShiftingLine() {
        let emulator = GhosttyTerminalEmulator(columns: 8, rows: 4)

        emulator.feed(Data("abcdef".utf8))
        emulator.feed(Data("\r\u{1b}[4G\u{1b}[2X".utf8))

        let cells = emulator.state.activeScreen.lines[0].cells
        XCTAssertEqual(cells[0].character, "a")
        XCTAssertEqual(cells[1].character, "b")
        XCTAssertEqual(cells[2].character, "c")
        XCTAssertEqual(cells[3].character, " ")
        XCTAssertEqual(cells[4].character, " ")
        XCTAssertEqual(cells[5].character, "f")
    }
}
