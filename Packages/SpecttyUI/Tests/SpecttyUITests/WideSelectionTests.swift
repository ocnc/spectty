import XCTest
import SpecttyTerminal
@testable import SpecttyUI

final class WideSelectionTests: XCTestCase {
    @MainActor func testSelectingEitherHalfCopiesOneWholeCharacter() {
        let emulator = GhosttyTerminalEmulator(columns: 8, rows: 4)
        emulator.feed(Data("a中b".utf8))
        let view = TextSelectionView(frame: .zero)
        for col in [1, 2] {
            view.selection = TerminalSelection(startRow: 0, startCol: col, endRow: 0, endCol: col)
            XCTAssertEqual(view.selectedText(from: emulator.state.activeScreen), "中")
        }
        view.selection = TerminalSelection(startRow: 0, startCol: 0, endRow: 0, endCol: 3)
        XCTAssertEqual(view.selectedText(from: emulator.state.activeScreen), "a中b")
    }
}
