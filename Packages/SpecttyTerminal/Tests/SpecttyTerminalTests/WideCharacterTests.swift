import XCTest
@testable import SpecttyTerminal

final class WideCharacterTests: XCTestCase {
    func testInsertionPreservesWideCharacters() {
        for (operation, expected) in [("\u{1b}[@", " 中a"), ("\u{1b}[4hX", "X中a"), ("\u{1b}[4h文", "文中a")] {
            let emulator = GhosttyTerminalEmulator(columns: 10, rows: 4)
            emulator.feed(Data("中a\r\(operation)".utf8))
            XCTAssertEqual(emulator.state.activeScreen.text(), expected)
        }
    }

    func testEraseDeleteAndOverwriteDoNotLeaveOrphanTails() {
        for operation in ["\u{1b}[X", "\u{1b}[P", "X", "\u{1b}[2G\u{1b}[@"] {
            let emulator = GhosttyTerminalEmulator(columns: 8, rows: 4)
            emulator.feed(Data("中a\r\(operation)".utf8))
            assertPairs(emulator)
        }
    }

    func testWrapResizeAndScrollbackPreserveText() {
        let emulator = GhosttyTerminalEmulator(columns: 4, rows: 2)
        emulator.feed(Data("abc中".utf8))
        XCTAssertEqual(emulator.state.activeScreen.text(), "abc\n中")
        emulator.feed(Data("\r\n文".utf8))
        XCTAssertEqual(emulator.state.scrollback.line(at: 0)?.textContent(), "abc")
        emulator.resize(columns: 1, rows: 2)
        assertPairs(emulator)
    }

    private func assertPairs(_ emulator: GhosttyTerminalEmulator, file: StaticString = #filePath, line: UInt = #line) {
        for row in emulator.state.activeScreen.lines {
            for index in row.cells.indices {
                if row.cells[index].isWideHead {
                    XCTAssertTrue(index + 1 < row.cells.count && row.cells[index + 1].isWideTail, file: file, line: line)
                }
                if row.cells[index].isWideTail {
                    XCTAssertTrue(index > 0 && row.cells[index - 1].isWideHead, file: file, line: line)
                }
            }
        }
    }
}
